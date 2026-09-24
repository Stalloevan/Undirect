// Minimal declarations of Tor's embedding API (feature/api/tor_api.h), linked
// from the prebuilt static tor xcframework downloaded during CI.
#ifndef Undirect_Bridging_Header_h
#define Undirect_Bridging_Header_h

typedef struct tor_main_configuration_t tor_main_configuration_t;

tor_main_configuration_t *tor_main_configuration_new(void);
int tor_main_configuration_set_command_line(tor_main_configuration_t *cfg, int argc, char *argv[]);
void tor_main_configuration_free(tor_main_configuration_t *cfg);
int tor_run_main(const tor_main_configuration_t *cfg);

#endif
