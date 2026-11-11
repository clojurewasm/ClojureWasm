/* `chez --script FILE` over the Chez kernel a jolt binary embeds.
 *
 * jolt build --library shells out to `chez` and reads scheme.h, libkernel.a
 * and the boot files from JOLT_CHEZ_CSV. The prebuilt jolt binary carries
 * all of them as data but does not use them for --library; build.sh pulls
 * them out and links this front end so no separate Chez install is needed.
 */
#include <stdio.h>
#include <string.h>
#include "scheme.h"

int main(int argc, char **argv) {
  char petite[4096], scheme[4096];
  if (argc < 3 || strcmp(argv[1], "--script") != 0) {
    fprintf(stderr, "usage: chez --script FILE [ARGS]\n");
    return 2;
  }
  snprintf(petite, sizeof petite, "%s/petite.boot", BOOTDIR);
  snprintf(scheme, sizeof scheme, "%s/scheme.boot", BOOTDIR);
  Sscheme_init(NULL);
  Sregister_boot_file(petite);
  Sregister_boot_file(scheme);
  Sbuild_heap(argv[0], NULL);
  int status = Sscheme_script(argv[2], argc - 2, (const char **)argv + 2);
  Sscheme_deinit();
  return status;
}
