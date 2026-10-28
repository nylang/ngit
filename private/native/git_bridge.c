/* Private ngit libgit2 snapshot backend. Never invokes Git, a shell, or checkout filters. */
#ifndef _WIN32
#define _DARWIN_C_SOURCE 1
#define _DEFAULT_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#endif
#include "git_bridge.h"
#include <git2.h>
#include <git2/sys/errors.h>
#include <openssl/evp.h>
#include <openssl/x509.h>
#include <openssl/err.h>
#include <openssl/x509err.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <sys/stat.h>
#include <time.h>
#ifdef _WIN32
#include <windows.h>
#include <wincrypt.h>
#include <io.h>
#include <direct.h>
#include <wchar.h>
#include "windows_paths.h"
#define mkdir_one(p) windows_mkdir(p)
#define open_file(p,m) windows_fopen(p,m)
#define close_fd _close
#define strdup _strdup
#else
#include <unistd.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/file.h>
#define mkdir_one(p) mkdir(p,0700)
#define open_file(p,m) fopen(p,m)
#define close_fd close
#endif

#define LIMIT (64u*1024u*1024u)
#define MAX_FILES 10000
struct member { char *path; git_oid oid; int executable; };
struct inventory { struct member *members; size_t len, cap, bytes; };
struct transfer { const char *url; uint64_t deadline; };

#ifdef _WIN32
/* Populate the process-local OpenSSL store from Windows trust anchors. Explicit
   caller CA configuration remains authoritative. Never import private keys or
   persist the certificate collection. Respect both user/machine distrust. */
static int windows_cert_disallowed(PCCERT_CONTEXT cert, HCERTSTORE user, HCERTSTORE machine) {
    unsigned char hash[20]; DWORD size=sizeof(hash);
    if(!CertGetCertificateContextProperty(cert,CERT_SHA1_HASH_PROP_ID,hash,&size))return 1;
    CRYPT_HASH_BLOB identity={size,hash}; HCERTSTORE stores[2]={user,machine};
    for(size_t i=0;i<2;i++)if(stores[i]){
        PCCERT_CONTEXT found=CertFindCertificateInStore(stores[i],X509_ASN_ENCODING|PKCS_7_ASN_ENCODING,0,CERT_FIND_SHA1_HASH,&identity,NULL);
        if(found){CertFreeCertificateContext(found);return 1;}
    }
    return 0;
}
static int windows_system_roots(void) {
    DWORD scopes[2]={CERT_SYSTEM_STORE_CURRENT_USER,CERT_SYSTEM_STORE_LOCAL_MACHINE};
    HCERTSTORE distrust[2]={NULL,NULL};int added=0,result=0;
    for(size_t i=0;i<2;i++)distrust[i]=CertOpenStore(CERT_STORE_PROV_SYSTEM_W,0,0,scopes[i]|CERT_STORE_READONLY_FLAG|CERT_STORE_OPEN_EXISTING_FLAG,L"Disallowed");
    for(size_t i=0;i<2&&!result;i++){
        HCERTSTORE store=CertOpenStore(CERT_STORE_PROV_SYSTEM_W,0,0,scopes[i]|CERT_STORE_READONLY_FLAG|CERT_STORE_OPEN_EXISTING_FLAG,L"ROOT");
        if(!store)continue;
        PCCERT_CONTEXT context=NULL;
        while((context=CertEnumCertificatesInStore(store,context))){
            if(windows_cert_disallowed(context,distrust[0],distrust[1]))continue;
            const unsigned char *data=context->pbCertEncoded;
            X509 *cert=d2i_X509(NULL,&data,(long)context->cbCertEncoded);
            if(!cert){ERR_clear_error();continue;}
            if(git_libgit2_opts(GIT_OPT_ADD_SSL_X509_CERT,cert)){
                if(ERR_GET_REASON(ERR_peek_last_error())!=X509_R_CERT_ALREADY_IN_HASH_TABLE)result=-1;
                else{git_error_clear();ERR_clear_error();}
            }
            X509_free(cert);
            if(result){CertFreeCertificateContext(context);break;}
            added++;
        }
        CertCloseStore(store,0);
    }
    for(size_t i=0;i<2;i++)if(distrust[i])CertCloseStore(distrust[i],0);
    return result||!added?-1:0;
}
#endif

static uint64_t now_ms(void) {
#ifdef _WIN32
    return GetTickCount64();
#else
    struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
    return (uint64_t)t.tv_sec*1000+(uint64_t)t.tv_nsec/1000000;
#endif
}
static char *join(const char *a,const char *b) {
    size_t n=strlen(a)+strlen(b)+2; char *p=malloc(n);
    if(p) snprintf(p,n,"%s/%s",a,b); return p;
}
static int directory(const char *p) {
#ifdef _WIN32
    wchar_t *wide=windows_path(p);if(!wide)return 0;
    DWORD attributes=GetFileAttributesW(wide);free(wide);
    return attributes!=INVALID_FILE_ATTRIBUTES&&(attributes&FILE_ATTRIBUTE_DIRECTORY);
#else
    struct stat s; return !stat(p,&s)&&S_ISDIR(s.st_mode);
#endif
}
static int make_dirs(const char *p) {
    char *s=strdup(p); if(!s)return -1;
    for(char *c=s+1;*c;c++) if(*c=='/'||*c=='\\') { char save=*c; *c=0;
        if(!(strlen(s)==2&&s[1]==':') && mkdir_one(s)&&errno!=EEXIST){free(s);return -1;} *c=save; }
    int r=mkdir_one(s); free(s); return r&&errno!=EEXIST?-1:0;
}
static int remove_tree(const char *p) {
#ifdef _WIN32
    char *pattern=join(p,"*");if(!pattern)return -1;
    wchar_t *wide=windows_path(pattern);free(pattern);if(!wide)return -1;
    WIN32_FIND_DATAW e;HANDLE h=FindFirstFileW(wide,&e);free(wide);int result=0;
    if(h!=INVALID_HANDLE_VALUE){do{
        if(!wcscmp(e.cFileName,L".")||!wcscmp(e.cFileName,L".."))continue;
        char *name=windows_utf8(e.cFileName);char *child=name?join(p,name):NULL;free(name);
        if(!child){result=-1;break;}
        if(e.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT){free(child);result=-1;break;}
        if(e.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)result=remove_tree(child);
        else{wide=windows_path(child);if(!wide)result=-1;
            else{if(!SetFileAttributesW(wide,FILE_ATTRIBUTE_NORMAL)||!DeleteFileW(wide))result=-1;free(wide);}}
        free(child);if(result)break;
    }while(FindNextFileW(h,&e));if(!result&&GetLastError()!=ERROR_NO_MORE_FILES)result=-1;FindClose(h);}
    else if(GetLastError()!=ERROR_FILE_NOT_FOUND)return -1;
    wide=windows_path(p);if(!wide)return -1;
    if(!result&&!RemoveDirectoryW(wide))result=-1;free(wide);return result;
#else
    struct stat st;if(lstat(p,&st))return 0;
    if(!S_ISDIR(st.st_mode))return unlink(p);
    chmod(p,0700); DIR *d=opendir(p);if(!d)return -1;struct dirent *e;
    while((e=readdir(d))){if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;
        char *child=join(p,e->d_name);if(!child){closedir(d);return -1;} remove_tree(child);free(child);}
    closedir(d);return rmdir(p);
#endif
}
static intptr_t take_lock(const char *path,int timeout_ms) {
    uint64_t deadline=now_ms()+(uint64_t)timeout_ms;
#ifdef _WIN32
    wchar_t *wide=windows_path(path);if(!wide)return -1;
    HANDLE h=CreateFileW(wide,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);free(wide);
    if(h==INVALID_HANDLE_VALUE)return -1; OVERLAPPED ov={0};
    while(!LockFileEx(h,LOCKFILE_EXCLUSIVE_LOCK|LOCKFILE_FAIL_IMMEDIATELY,0,1,0,&ov)){
        if(GetLastError()!=ERROR_LOCK_VIOLATION||now_ms()>deadline){CloseHandle(h);return -1;}Sleep(10);
    }return (intptr_t)h;
#else
    int fd=open(path,O_CREAT|O_RDWR,0600);if(fd<0)return -1;
    while(flock(fd,LOCK_EX|LOCK_NB)){
        if((errno!=EWOULDBLOCK&&errno!=EINTR)||now_ms()>deadline){close(fd);return -1;}
        struct timespec delay={0,10000000};nanosleep(&delay,NULL);
    }return fd;
#endif
}
static void drop_lock(intptr_t h) {
    if(h==-1)return;
#ifdef _WIN32
    OVERLAPPED ov={0};UnlockFileEx((HANDLE)h,0,1,0,&ov);CloseHandle((HANDLE)h);
#else
    flock((int)h,LOCK_UN);close((int)h);
#endif
}
static int publish(const char *from,const char *to) {
#ifdef _WIN32
    wchar_t *source=windows_path(from),*target=windows_path(to);int result=-1;
    if(source&&target)result=MoveFileExW(source,target,MOVEFILE_WRITE_THROUGH)?0:-1;
    free(source);free(target);return result;
#else
    return rename(from,to);
#endif
}
static void hex(const unsigned char *data,size_t n,char *out){static const char digits[]="0123456789abcdef";
    for(size_t i=0;i<n;i++){out[2*i]=digits[data[i]>>4];out[2*i+1]=digits[data[i]&15];}out[2*n]=0;}
static int hash_bytes(const void *data,size_t n,char out[65]) {
    unsigned char raw[32];unsigned size=0;
    if(!EVP_Digest(data,n,raw,&size,EVP_sha256(),NULL)||size!=32)return -1;hex(raw,32,out);return 0;
}
static char *input(const char *p,int32_t n){if(!p||n<=0||n>32768||memchr(p,0,(size_t)n)||memchr(p,'\n',(size_t)n)||memchr(p,'\r',(size_t)n))return NULL;
    char *out=malloc((size_t)n+1);if(out){memcpy(out,p,(size_t)n);out[n]=0;}return out;}
static int origin_allowed(const char *url){
    if(!strncmp(url,"https://",8)){const char *end=strchr(url+8,'/');if(!end)end=url+strlen(url);
        return !memchr(url+8,'@',(size_t)(end-url-8))&&!strchr(url,'?')&&!strchr(url,'#');}
    if(!strncmp(url,"file:///",8))return 1;
    return url[0]=='/'||(strlen(url)>2&&url[1]==':'&&(url[2]=='/'||url[2]=='\\'));
}
static int same_authority(const char *a,const char *b){const char *x=strstr(a,"://"),*y=strstr(b,"://");if(!x||!y)return 0;
    const char *xe=strchr(x+3,'/'),*ye=strchr(y+3,'/');if(!xe)xe=a+strlen(a);if(!ye)ye=b+strlen(b);
    return xe-a==ye-b&&!memcmp(a,b,(size_t)(xe-a));}
/* ngit names are preferred; legacy Nyra manager configuration remains compatible. */
static const char *git_environment(const char *name, const char *legacy) {
    const char *value = getenv(name);
    return value && *value ? value : getenv(legacy);
}
static int credentials(git_credential **out,const char *url,const char *user,unsigned allowed,void *payload){
    struct transfer *t=payload;const char *token=git_environment("NGIT_TOKEN","NYRA_GIT_TOKEN"),*name=git_environment("NGIT_USERNAME","NYRA_GIT_USERNAME");(void)user;
    if(!same_authority(url,t->url)||!token||!name||!(allowed&GIT_CREDENTIAL_USERPASS_PLAINTEXT))return GIT_PASSTHROUGH;
    return git_credential_userpass_plaintext_new(out,name,token);
}
static int progress(const git_indexer_progress *stats,void *payload){(void)stats;struct transfer *t=payload;return now_ms()>t->deadline||stats->received_bytes>256u*1024u*1024u||stats->total_objects>1000000?GIT_EUSER:0;}
static int sideband(const char *text,int len,void *payload){(void)text;(void)len;struct transfer *t=payload;return now_ms()>t->deadline?GIT_EUSER:0;}
static int safe_component(const char *s){
    if(!*s||!strcmp(s,".")||!strcmp(s,"..")||!strcmp(s,".git")||!strcmp(s,".nyra"))return 0;
    for(;*s;s++)if((unsigned char)*s<32||strchr("\\/:*?\"<>|",*s))return 0;return 1;
}
static int collect(git_repository *repo,git_tree *tree,const char *prefix,struct inventory *inv,unsigned depth){
    if(depth>64)return -1;
    for(size_t i=0;i<git_tree_entrycount(tree);i++){
        const git_tree_entry *e=git_tree_entry_byindex(tree,i);const char *name=git_tree_entry_name(e);
        if(!safe_component(name))return -1;
        char *path=*prefix?join(prefix,name):strdup(name);if(!path)return -1;
        git_filemode_t mode=git_tree_entry_filemode(e);
        if(mode==GIT_FILEMODE_TREE){git_tree *child=NULL;int r=git_tree_lookup(&child,repo,git_tree_entry_id(e));
            if(!r)r=collect(repo,child,path,inv,depth+1);git_tree_free(child);free(path);if(r)return -1;
        }else if(mode==GIT_FILEMODE_BLOB||mode==GIT_FILEMODE_BLOB_EXECUTABLE){
            if(inv->len>=MAX_FILES){free(path);return -1;}if(inv->len==inv->cap){size_t n=inv->cap?inv->cap*2:32;
                void *p=realloc(inv->members,n*sizeof(*inv->members));if(!p){free(path);return -1;}inv->members=p;inv->cap=n;}
            inv->members[inv->len++]=(struct member){.path=path,.oid=*git_tree_entry_id(e),.executable=mode==GIT_FILEMODE_BLOB_EXECUTABLE};
        }else {free(path);return -1;}
    }return 0;
}
static int compare_member(const void *a,const void *b){return strcmp(((const struct member*)a)->path,((const struct member*)b)->path);}
static int export_tree(git_repository *repo,git_tree *tree,const char *dest,char digest[65]){
    struct inventory inv={0};EVP_MD_CTX *hash=NULL;git_odb *odb=NULL;int result=-1;
    if(git_repository_odb(&odb,repo)||collect(repo,tree,"",&inv,0))goto done;
    if(make_dirs(dest))goto done;
    if(inv.len>1)qsort(inv.members,inv.len,sizeof(*inv.members),compare_member);
    hash=EVP_MD_CTX_new();if(!hash||!EVP_DigestInit_ex(hash,EVP_sha256(),NULL))goto done;
    static const char header[]="nyra-package-content-v1\n";EVP_DigestUpdate(hash,header,sizeof(header)-1);
    for(size_t i=0;i<inv.len;i++){
        struct member *m=&inv.members[i];git_blob *blob=NULL;size_t object_size=0;git_object_t object_type;
        if(git_odb_read_header(&object_size,&object_type,odb,&m->oid)||object_type!=GIT_OBJECT_BLOB||object_size>LIMIT||inv.bytes>LIMIT-object_size)goto done;
        if(git_blob_lookup(&blob,repo,&m->oid))goto done;
        size_t n=(size_t)git_blob_rawsize(blob);const char *bytes=git_blob_rawcontent(blob);
        if(n>LIMIT||inv.bytes>LIMIT-n||strlen(m->path)>4096){git_blob_free(blob);goto done;}inv.bytes+=n+strlen(m->path)+32;
        if(inv.bytes>LIMIT||(n>=42&&!memcmp(bytes,"version https://git-lfs.github.com/spec/v1",42))){git_blob_free(blob);goto done;}
        char frame[64];int count=snprintf(frame,sizeof(frame),"%zu\n",strlen(m->path));EVP_DigestUpdate(hash,frame,(size_t)count);
        EVP_DigestUpdate(hash,m->path,strlen(m->path));EVP_DigestUpdate(hash,"\n",1);
        count=snprintf(frame,sizeof(frame),"%zu\n",n);EVP_DigestUpdate(hash,frame,(size_t)count);EVP_DigestUpdate(hash,bytes,n);
        char *path=join(dest,m->path);if(!path){git_blob_free(blob);goto done;}
        char *slash=strrchr(path,'/');*slash=0;int mk=make_dirs(path);*slash='/';if(mk){free(path);git_blob_free(blob);goto done;}
        FILE *f=open_file(path,"wb");if(!f){free(path);git_blob_free(blob);goto done;}
        int bad=fwrite(bytes,1,n,f)!=n;if(fflush(f))bad=1;
#ifndef _WIN32
        if(fsync(fileno(f)))bad=1;
#endif
        if(fclose(f))bad=1;
#ifndef _WIN32
        if(chmod(path,m->executable?0555:0444))bad=1;
#endif
        free(path);git_blob_free(blob);if(bad)goto done;
    }
    unsigned char raw[32];unsigned size=0;if(!EVP_DigestFinal_ex(hash,raw,&size)||size!=32)goto done;hex(raw,32,digest);result=0;
 done:
    git_odb_free(odb);EVP_MD_CTX_free(hash);for(size_t i=0;i<inv.len;i++)free(inv.members[i].path);free(inv.members);return result;
}
static char *new_stage(const char *root,const char *key){
    char label[96];
#ifdef _WIN32
    static unsigned serial;snprintf(label,sizeof(label),"op-%s-%lu-%u",key,(unsigned long)GetCurrentProcessId(),++serial);
    char *p=join(root,label);if(!p||mkdir_one(p)){free(p);return NULL;}return p;
#else
    snprintf(label,sizeof(label),"op-%s-XXXXXX",key);char *p=join(root,label);if(!p||!mkdtemp(p)){free(p);return NULL;}return p;
#endif
}
static void reclaim_staging(const char *root,const char *key){
    /* The caller holds this origin's process lock. Other origins have different prefixes. */
#ifndef _WIN32
    DIR *d=opendir(root);if(!d)return;struct dirent *e;char prefix[80];snprintf(prefix,sizeof(prefix),"op-%s-",key);
    while((e=readdir(d))){if(strncmp(e->d_name,prefix,strlen(prefix)))continue;char *p=join(root,e->d_name);if(p){remove_tree(p);free(p);}}closedir(d);
#else
    char prefix[80];snprintf(prefix,sizeof(prefix),"op-%s-*",key);char *pattern=join(root,prefix);if(!pattern)return;
    wchar_t *wide=windows_path(pattern);free(pattern);if(!wide)return;
    WIN32_FIND_DATAW e;HANDLE h=FindFirstFileW(wide,&e);free(wide);
    if(h!=INVALID_HANDLE_VALUE){do{char *name=windows_utf8(e.cFileName);char *p=name?join(root,name):NULL;free(name);
        if(p){remove_tree(p);free(p);}}while(FindNextFileW(h,&e));FindClose(h);}
#endif
}
int32_t ngit_prepare_snapshot(const char *url_data,int32_t url_len,const char *rev_data,int32_t rev_len,const char *cache_data,int32_t cache_len,int32_t offline,int32_t timeout_ms,char *output,int32_t capacity){
    char *url=input(url_data,url_len),*rev=input(rev_data,rev_len),*cache=input(cache_data,cache_len);
    char *gitdir=NULL,*packages=NULL,*locks=NULL,*staging=NULL,*mirror=NULL,*lockpath=NULL,*stage=NULL,*clonepath=NULL,*content=NULL,*target=NULL,*content_lockpath=NULL;
    git_repository *repo=NULL;git_object *object=NULL,*commit_object=NULL;git_tree *tree=NULL;git_remote *remote=NULL;
    intptr_t origin_lock=-1,content_lock=-1;int initialized=0,result=-3;
    char origin_id[65],digest[65],commit_id[GIT_OID_SHA1_HEXSIZE+1];
    if(!url||!rev||!cache||!output||capacity<256||timeout_ms<1||timeout_ms>120000)goto done;
    if(!origin_allowed(url)){result=-2;goto done;}
    gitdir=join(cache,"git");packages=join(cache,"packages");locks=join(cache,"locks");staging=join(cache,"staging");
    if(!gitdir||!packages||!locks||!staging)goto done;
    if(offline&&!directory(gitdir)){result=-6;goto done;}
    if(make_dirs(gitdir)||make_dirs(packages)||make_dirs(locks)||make_dirs(staging))goto done;
    if(hash_bytes(url,strlen(url),origin_id))goto done;
    mirror=join(gitdir,origin_id);lockpath=join(locks,origin_id);if(!mirror||!lockpath)goto done;
    origin_lock=take_lock(lockpath,timeout_ms);if(origin_lock==-1)goto done;
    reclaim_staging(staging,origin_id);stage=new_stage(staging,origin_id);if(!stage)goto done;
    if(git_libgit2_init()<0)goto done;initialized=1;
    git_libgit2_opts(GIT_OPT_SET_PACK_MAX_OBJECT_SIZE,(size_t)LIMIT);
    git_libgit2_opts(GIT_OPT_SET_SERVER_CONNECT_TIMEOUT,timeout_ms);git_libgit2_opts(GIT_OPT_SET_SERVER_TIMEOUT,timeout_ms);
    const char *ca=git_environment("NGIT_CA_FILE","NYRA_GIT_CA_FILE");
#ifndef _WIN32
    /* An SDK must not require the build machine's OpenSSL prefix for public trust. */
    if((!ca||!*ca)&&!getenv("SSL_CERT_FILE")){
        struct stat trust_stat;const char *compiled=X509_get_default_cert_file();
        if(!compiled||stat(compiled,&trust_stat)||!S_ISREG(trust_stat.st_mode)){
            static const char *system_roots[]={"/etc/ssl/cert.pem","/etc/ssl/certs/ca-certificates.crt","/etc/pki/tls/certs/ca-bundle.crt",NULL};
            for(size_t i=0;system_roots[i];i++)if(!stat(system_roots[i],&trust_stat)&&S_ISREG(trust_stat.st_mode)){ca=system_roots[i];break;}
        }
    }
#endif
#ifdef _WIN32
    if((!ca||!*ca)&&!getenv("SSL_CERT_FILE")&&!getenv("SSL_CERT_DIR")&&!strncmp(url,"https://",8)&&windows_system_roots()){result=-1;goto done;}
#endif
    if(ca&&*ca&&git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS,ca,NULL)){result=-1;goto done;}
    struct transfer transfer={url,now_ms()+(uint64_t)timeout_ms};
    git_fetch_options fetch=GIT_FETCH_OPTIONS_INIT;
    /* Honor the host's explicit Git/HTTP proxy configuration without a shell. */
    fetch.proxy_opts.type=GIT_PROXY_AUTO;
    fetch.callbacks.credentials=credentials;fetch.callbacks.transfer_progress=progress;fetch.callbacks.sideband_progress=sideband;fetch.callbacks.payload=&transfer;fetch.follow_redirects=GIT_REMOTE_REDIRECT_NONE;
    if(!directory(mirror)){
        if(offline){result=-6;goto done;}clonepath=join(stage,"repository");if(!clonepath)goto done;
        git_clone_options opts=GIT_CLONE_OPTIONS_INIT;opts.bare=1;opts.fetch_opts=fetch;
        if(git_clone(&repo,url,clonepath,&opts)){result=-1;goto done;}
        git_repository_free(repo);repo=NULL;if(publish(clonepath,mirror))goto done;
    }
    if(git_repository_open_bare(&repo,mirror))goto done;
    if(git_repository_oid_type(repo)!=GIT_OID_SHA1){result=-9;goto done;}
    int fixed_revision=strlen(rev)==40;
    for(size_t i=0;fixed_revision&&i<40;i++)if(!strchr("0123456789abcdef",rev[i]))fixed_revision=0;
    if(!fixed_revision&&!offline){
        /* Explicit tag refspecs must override auto-follow's keep-local-tag behavior. */
        fetch.download_tags=GIT_REMOTE_DOWNLOAD_TAGS_NONE;
        char *specs[]={"+refs/heads/*:refs/heads/*","+refs/tags/*:refs/tags/*"};
        git_strarray refspecs={specs,2};
        if(git_remote_lookup(&remote,repo,"origin")||git_remote_fetch(remote,&refspecs,&fetch,NULL)){result=-4;goto done;}
    }
    if(git_revparse_single(&object,repo,rev)){
        if(offline){result=-6;goto done;}
        if((!remote&&git_remote_lookup(&remote,repo,"origin"))||git_remote_fetch(remote,NULL,&fetch,NULL)||git_revparse_single(&object,repo,rev)){result=-4;goto done;}
    }
    if(git_object_peel(&commit_object,object,GIT_OBJECT_COMMIT)||git_commit_tree(&tree,(git_commit*)commit_object)){result=-4;goto done;}
    git_oid_tostr(commit_id,sizeof(commit_id),git_object_id(commit_object));
    content=join(stage,"content");if(!content)goto done;
    if(export_tree(repo,tree,content,digest)){result=-5;goto done;}
    target=join(packages,digest);content_lockpath=join(locks,digest);if(!target||!content_lockpath)goto done;
    content_lock=take_lock(content_lockpath,timeout_ms);if(content_lock==-1)goto done;
    char *final_content=join(target,"content");if(!final_content)goto done;
    if(!directory(final_content)){
        char *publication=join(stage,"publication");char *publication_content=publication?join(publication,"content"):NULL;
        if(!publication||!publication_content||make_dirs(publication)||publish(content,publication_content)||publish(publication,target)){free(publication);free(publication_content);free(final_content);goto done;}
        free(publication);free(publication_content);
    }
    free(final_content);
    result=snprintf(output,(size_t)capacity,"%s\n%s\npackages/%s/content",commit_id,digest,digest);
    if(result<0||result>=capacity)result=-3;
 done:
    git_remote_free(remote);git_tree_free(tree);git_object_free(commit_object);git_object_free(object);git_repository_free(repo);if(initialized)git_libgit2_shutdown();
    drop_lock(content_lock);if(stage)remove_tree(stage);drop_lock(origin_lock);
    free(url);free(rev);free(cache);free(gitdir);free(packages);free(locks);free(staging);free(mirror);free(lockpath);free(stage);free(clonepath);free(content);free(target);free(content_lockpath);
    return result;
}
