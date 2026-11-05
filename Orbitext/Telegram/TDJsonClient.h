#ifndef TDJsonClient_h
#define TDJsonClient_h

/// Bridging header for TDLib's tdjson C API.

#define TDJSON_STATIC_DEFINE

int td_create_client_id(void);
void td_send(int client_id, const char *request);
const char *td_receive(double timeout);
const char *td_execute(const char *request);

typedef void (*td_log_message_callback_ptr)(int verbosity_level, const char *message);
void td_set_log_message_callback(int max_verbosity_level, td_log_message_callback_ptr callback);

#endif /* TDJsonClient_h */
