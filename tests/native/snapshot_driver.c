/* Native sanitizer driver for the ngit private snapshot ABI; fixtures live under cache/. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "git_bridge.h"
int main(int argc,char **argv) {
    if(argc==2&&!strcmp(argv[1],"--invalid")){
        char buffer[512];
        if(ngit_prepare_snapshot(NULL,1,NULL,1,NULL,1,0,1000,buffer,sizeof(buffer))>=0)return 1;
        if(ngit_prepare_snapshot("/x",2,"x",1,"/x",2,0,0,buffer,sizeof(buffer))>=0)return 1;
        if(ngit_prepare_snapshot("/x",2,"x",1,"/x",2,0,1000,NULL,512)>=0)return 1;
        return 0;
    }
    if(argc!=5)return 2;
    char output[512]={0};
    int result=ngit_prepare_snapshot(argv[1],(int)strlen(argv[1]),argv[2],(int)strlen(argv[2]),argv[3],(int)strlen(argv[3]),atoi(argv[4]),1000,output,sizeof(output));
    if(result<0){fprintf(stderr,"private Git status %d\n",result);return 1;}
    fwrite(output,1,(size_t)result,stdout);return 0;
}
