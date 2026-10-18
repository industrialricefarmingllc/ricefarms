#include <cstdio>
#include <string>
#include <fstream>
#include <algorithm>
static const char* jsSkip(const char* p, const char* end){while(p<end&&(*p==' '||*p=='\t'||*p=='\n'||*p=='\r'))++p;return p;}
static const char* jsMatch(const char* p, const char* end, char open, char close){
    int depth=0;bool inStr=false;
    for(;p<end;++p){
        if(inStr){if(*p=='\\')++p;else if(*p=='"')inStr=false;}
        else if(*p=='"')inStr=true;
        else if(*p==open)++depth;
        else if(*p==close){if(--depth==0)return p;}
    }
    return end;
}
int main(){
    std::ifstream f("/home/nicerice/.cache/liquid-glass-hypr/liquidglass-bar-DP-1.json");
    std::string t((std::istreambuf_iterator<char>(f)),std::istreambuf_iterator<char>());
    const char*p=t.data(),*end=p+t.size();
    const char* q=p+38+1; // just after pills [
    const char* pEnd=p+1133;
    int iter=0;
    while(true){
        q=jsSkip(q,pEnd);
        printf("iter %d: q off=%ld char='%c'\n",iter,(long)(q-p),q<pEnd?*q:'?');
        if(q>=pEnd){printf("EXIT-EOF\n");break;}
        if(*q==']'){printf("EXIT-BRACKET\n");break;}
        if(*q==','){++q;continue;}
        if(*q!='{'){printf("EXIT-NONBRACE\n");break;}
        const char* eEnd=jsMatch(q,pEnd,'{','}');
        printf("  obj } at %ld\n",(long)(eEnd-p));
        if(eEnd==pEnd){printf("EXIT-UNBAL\n");break;}
        q=eEnd+1;
        if(++iter>8){printf("OVER-RUN\n");break;}
    }
    return 0;
}
