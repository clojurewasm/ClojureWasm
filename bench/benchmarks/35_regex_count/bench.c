#include <stdio.h>
#include <regex.h>

int main(void) {
    const char *s = "a12b345c6789d0e";
    regex_t re;
    regcomp(&re, "[0-9]+", REG_EXTENDED);
    int total = 0;
    for (int i = 0; i < 10000; i++) {
        int c = 0;
        const char *p = s;
        regmatch_t m;
        while (regexec(&re, p, 1, &m, 0) == 0) {
            c++;
            if (m.rm_eo == 0) break;
            p += m.rm_eo;
        }
        total = c;
    }
    regfree(&re);
    printf("%d\n", total);
    return 0;
}
