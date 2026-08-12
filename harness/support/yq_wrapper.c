#include <errno.h>
#include <process.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
  const char *python = getenv("LVB_E2E_PYTHON");
  const char *script = getenv("LVB_E2E_YQ_SCRIPT");
  intptr_t result;

  if (python == NULL || script == NULL) {
    fputs("LVB_E2E_PYTHON and LVB_E2E_YQ_SCRIPT are required.\n", stderr);
    return 2;
  }
  result = _spawnl(_P_WAIT, python, "python", script, (char *)NULL);
  if (result == -1) {
    fprintf(stderr, "Failed to start yq compatibility converter (errno %d).\n", errno);
    return 127;
  }
  return (int)result;
}
