#include <cstdio>
#include <string>
#include <fstream>
#include <algorithm>
static const char* jsSkip(const char* p, const char* end){while(p<end&&(*p==' '||*p=='\t'||*p=='\n'||*p=='\r'))++p;return p;}
static const char* jsMatch(const char* p, const char* end, char open, char close){
    int depth=0;bool inStr=false;const char* start=p;
    for(;p<end;++p){
        if(inStr){if(*p=='\\')++p;else if(*p=='"')inStr=false;}
        else if(*p=='"')inStr=true;
        else if(*p==open)++depth;
        else if(*p==close){if(--depth==0)return p;}
    }
    printf("UNBALANCED %c..%c from off %ld depth=%d inStr=%d\n",open,close,(long)(start-(const char*)0),depth,inStr);
    return end;
}
int main(){
    std::ifstream f("/home/nicerice/.cache/liquid-glass-hypr/liquidglass-bar-DP-1.json");
    std::string t((std::istreambuf_iterator<char>(f)),std::istreambuf_iterator<char>());
    const char*p=t.data(),*end=p+t.size();
    printf("filesize=%ld\n",(long)t.size());
    const char* a=p; std::string n="\"pills\"";
    a=std::search(a,end,n.begin(),n.end()); printf("pills key at %ld\n",(long)(a-p));
    const char* q=a+n.size(); q=jsSkip(q,end); while(q<end&&*q!='[')++q;
    printf("[ at %ld\n",(long)(q-p));
    const char* pEnd=jsMatch(q,end,'[',']');
    printf("match ] at %ld char='%c' context=%.40s\n",(long)(pEnd-p),pEnd<end?*pEnd:'?',pEnd<end?pEnd:"END");
    return 0;
}
