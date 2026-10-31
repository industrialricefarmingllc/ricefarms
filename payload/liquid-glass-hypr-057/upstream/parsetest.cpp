// Extract of Glass.cpp geometry parsing, byte-identical logic, standalone.
// Usage: parsetest <jsonfile> <surfX> <surfY> <surfW> <surfH>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <fstream>
#include <algorithm>
struct SPill { float x,y,w,h,r[4]; };
static const char* jsSkip(const char* p, const char* end) {
    while (p < end && (*p==' '||*p=='\t'||*p=='\n'||*p=='\r')) ++p;
    return p;
}
static const char* jsMatch(const char* p, const char* end, char open, char close) {
    int depth=0; bool inStr=false;
    for (; p<end; ++p) {
        if (inStr) { if (*p=='\\') ++p; else if (*p=='"') inStr=false; }
        else if (*p=='"') inStr=true;
        else if (*p==open) ++depth;
        else if (*p==close) { if (--depth==0) return p; }
    }
    return end;
}
static bool jsNumber(const char*& p, const char* end, double& out) {
    p=jsSkip(p,end); char* stop=nullptr; out=std::strtod(p,&stop);
    if (stop==p) return false; p=stop; return true;
}
static bool findKey(const char*& p, const char* end, const char* key) {
    const std::string needle=std::string("\"")+key+"\"";
    const char* at=std::search(p,end,needle.begin(),needle.end());
    if (at==end) return false;
    p=at+needle.size(); p=jsSkip(p,end);
    if (p<end && *p==':') ++p;
    return true;
}
int main(int argc, char** argv) {
    if (argc!=6) return 2;
    double sx=atof(argv[2]),sy=atof(argv[3]),sw_=atof(argv[4]),sh_=atof(argv[5]);
    std::ifstream f(argv[1]); std::string text((std::istreambuf_iterator<char>(f)),std::istreambuf_iterator<char>());
    const char *p=text.data(), *end=p+text.size();
    const char* q=p;
    if (!findKey(q,end,"surface")) { printf("NO surface key\n"); return 1; }
    q=jsSkip(q,end); if (q>=end||*q!='{') { printf("NO surface obj\n"); return 1; }
    const char* sEnd=jsMatch(q,end,'{','}'); if (sEnd==end) { printf("UNBAL surface\n"); return 1; }
    double sw=0,sh=0;
    { const char* t=q; if(!findKey(t,sEnd,"w")||!jsNumber(t,sEnd,sw)){printf("NO w\n");return 1;} }
    { const char* t=q; if(!findKey(t,sEnd,"h")||!jsNumber(t,sEnd,sh)){printf("NO h\n");return 1;} }
    printf("declared surface %g x %g\n", sw, sh);
    double ratioX=sw_/sw, ratioY=sh_/sh;
    printf("ratio %g %g\n", ratioX, ratioY);
    if (ratioX<0.5||ratioX>4.0||ratioY<0.5||ratioY>4.0||std::abs(ratioX-ratioY)>0.05*(ratioX+ratioY)*0.5){printf("RATIO REJECT\n");return 1;}
    q=p; if(!findKey(q,end,"pills")){printf("NO pills\n");return 1;}
    q=jsSkip(q,end); if(q>=end||*q!='['){printf("NO [\n");return 1;}
    const char* pEnd=jsMatch(q,end,'[',']'); if(pEnd==end){printf("UNBAL [\n");return 1;}
    ++q; int n=0; bool fileOk=true;
    const char* pLim = pEnd + 1;
    while(true){
        q=jsSkip(q,pLim);
        if(q>=pLim){fileOk=false;break;}
        if(*q==']'){++q;break;}
        if(*q==','){++q;continue;}
        if(*q!='{'){fileOk=false;break;}
        const char* eEnd=jsMatch(q,pLim,'{','}');
        if(eEnd>=pLim){fileOk=false;break;}
        double x,y,w,h; bool ok=false; double radii[4]={0,0,0,0};
        do{
            const char* t=q;
            if(!findKey(t,eEnd,"x")||!jsNumber(t,eEnd,x))break;
            t=q; if(!findKey(t,eEnd,"y")||!jsNumber(t,eEnd,y))break;
            t=q; if(!findKey(t,eEnd,"w")||!jsNumber(t,eEnd,w))break;
            t=q; if(!findKey(t,eEnd,"h")||!jsNumber(t,eEnd,h))break;
            ok=true; t=q;
            if(findKey(t,eEnd,"r")){
                t=jsSkip(t,eEnd);
                if(t>=eEnd||*t!='['){ok=false;break;}
                const char* rEnd=jsMatch(t,eEnd,'[',']');
                if(rEnd==eEnd){ok=false;break;}
                ++t;
                for(int i=0;i<4&&ok;i++){t=jsSkip(t,rEnd);ok=jsNumber(t,rEnd,radii[i]);t=jsSkip(t,rEnd);if(t<rEnd&&*t==',')++t;}
            }
        }while(false);
        if(!ok||w<=0||h<=0){fileOk=false;break;}
        q=eEnd+1;
        printf("pill fb x=%g y=%g w=%g h=%g r=%g\n", sx+x*ratioX, sy+y*ratioY, w*ratioX, h*ratioY, radii[0]*(ratioX+ratioY)*0.5);
        ++n;
    }
    printf("fileOk=%d pills=%d\n", fileOk, n);
    return fileOk&&n>0?0:1;
}
