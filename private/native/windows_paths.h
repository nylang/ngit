// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/* Private UTF-8 filesystem adapter. No process policy or drive mappings. */
#ifndef NGIT_PRIVATE_WINDOWS_PATHS_H
#define NGIT_PRIVATE_WINDOWS_PATHS_H

/* Keep this adapter independent of its includer's system-header order. */
#include <windows.h>
#include <direct.h>
#include <errno.h>
#include <io.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <wchar.h>

static wchar_t *windows_path(const char *path) {
    int size=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,NULL,0);
    if(!size||size>32760)return NULL;
    wchar_t *input=malloc((size_t)size*sizeof(wchar_t));if(!input)return NULL;
    if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,input,size)){free(input);return NULL;}
    for(wchar_t *c=input;*c;c++)if(*c==L'/')*c=L'\\';
    /* Only ordinary absolute/relative paths enter this adapter. */
    if(!wcsncmp(input,L"\\\\?\\",4)||!wcsncmp(input,L"\\\\.\\",4)){free(input);return NULL;}
    DWORD needed=GetFullPathNameW(input,0,NULL,NULL);
    if(!needed||needed>32760){free(input);return NULL;}
    wchar_t *absolute=malloc((size_t)needed*sizeof(wchar_t));if(!absolute){free(input);return NULL;}
    DWORD count=GetFullPathNameW(input,needed,absolute,NULL);free(input);
    if(!count||count>=needed){free(absolute);return NULL;}
    int unc=absolute[0]==L'\\'&&absolute[1]==L'\\';
    size_t length=wcslen(absolute)+(unc?6:4)+1;
    if(length>32767){free(absolute);return NULL;}
    wchar_t *result=malloc(length*sizeof(wchar_t));if(result){
        wcscpy(result,unc?L"\\\\?\\UNC\\":L"\\\\?\\");wcscat(result,absolute+(unc?2:0));}
    free(absolute);return result;
}
static int windows_mkdir(const char *path) {
    wchar_t *wide=windows_path(path);if(!wide){errno=EINVAL;return -1;}
    int result=CreateDirectoryW(wide,NULL)?0:-1;
    DWORD error=result?GetLastError():0;
    /* EEXIST only accepts a real directory, not a colliding regular file. */
    if(result&&error==ERROR_ALREADY_EXISTS){DWORD attributes=GetFileAttributesW(wide);
        errno=attributes!=INVALID_FILE_ATTRIBUTES&&(attributes&FILE_ATTRIBUTE_DIRECTORY)?EEXIST:ENOTDIR;}
    else if(result)errno=EACCES;
    free(wide);return result;
}
static FILE *windows_fopen(const char *path,const char *mode) {
    wchar_t *wide=windows_path(path);if(!wide)return NULL;
    FILE *result=_wfopen(wide,!strcmp(mode,"wb")?L"wb":L"rb");free(wide);return result;
}
#endif
