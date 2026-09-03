#include <security/_pam_types.h>
#include <stdio.h>

int main(void) {
    printf("{ \"maxResponseSize\": %d, \"source\": \"c-header\" }\n",
           PAM_MAX_RESP_SIZE);
    return 0;
}
