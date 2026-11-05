// Offline boundary fakes around the verbatim DeviceTokenManager::on_result body.
// No TDLib client, database, networking, or user token is instantiated.
#include <algorithm>
#include <array>
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>

using int32 = int;
using int64 = long long;
using uint64 = unsigned long long;
struct Status {
  int value = 0;
  std::string text;
  int code() const { return value; }
  const std::string &message() const { return text; }
};
struct Result {
  Status failure;
  bool flag = true;
  bool is_ok() const { return failure.code() == 0; }
  bool is_error() const { return !is_ok(); }
  bool ok() const { return flag; }
  Status &error() { return failure; }
  Status move_as_error() { return std::move(failure); }
};
namespace telegram_api {
struct account_registerDevice { using ReturnType = bool; };
struct account_unregisterDevice { using ReturnType = bool; };
}
namespace td_api {
struct pushReceiverId {
  explicit pushReceiverId(int64 value) : value(value) {}
  int64 value;
};
template <class T> T make_object(int64 value) { return T(value); }
}
struct Query {
  uint64 request_id;
  Result result;
  bool cleared = false;
  uint64 id() const { return request_id; }
  void clear() { cleared = true; }
};
using NetQueryPtr = std::shared_ptr<Query>;
template <class T> Result fetch_result(NetQueryPtr query) { return std::move(query->result); }
struct Promise {
  bool pending = true;
  int completions = 0;
  Status error;
  int64 receiver = 0;
  explicit operator bool() const { return pending; }
  void set_error(Status value) { if (pending) { error = std::move(value); ++completions; pending = false; } }
  void set_error(int code, const char *message) { set_error(Status{code, message}); }
  void set_value(td_api::pushReceiverId value) { if (pending) { receiver = value.value; ++completions; pending = false; } }
};
struct Global {
  bool is_expected_error(const Status &error) const { return error.code() == 429; }
  static int32 get_retry_after(const Status &error) {
    if (error.code() != 429) return 0;
    return std::stoi(error.message().substr(std::string("Too Many Requests: retry after ").size()));
  }
  int64 get_option_integer(const char *) const { return 101; }
};
Global *G() { static Global global; return &global; }
struct Sink { template <class T> Sink &operator<<(const T &) { return *this; } };
#define LOG(level) Sink()
#define CHECK(condition) do { if (!(condition)) throw std::runtime_error("native CHECK failed: " #condition); } while (false)
template <class T> T clamp(T value, T minimum, T maximum) { return std::max(minimum, std::min(value, maximum)); }

class DeviceTokenManager {
 public:
  enum TokenType : int32 { Apns = 1, Fcm = 2, Size = 14 };
  struct TokenInfo {
    enum class State : int32 { Sync, Unregister, Register, Reregister };
    State state = State::Reregister;
    std::string token = "synthetic-invalid-token";
    uint64 net_query_id = 41;
    bool encrypt = false;
    int64 encryption_key_id = 102;
    Promise promise;
  };
  std::array<TokenInfo, Size> tokens_;
  int link_token = Apns;
  int saves = 0;
  int saved_slot = 0;
  TokenInfo::State saved_state = TokenInfo::State::Register;
  std::string saved_token;
  std::vector<int> timeouts;
  int get_link_token() const { return link_token; }
  void set_timeout_in(int delay) { timeouts.push_back(delay); }
  // Spy on the production persistence boundary; never open a real binlog.
  void save_info(int slot) {
    ++saves; saved_slot = slot; saved_state = tokens_[slot].state; saved_token = tokens_[slot].token;
  }
  void on_result(NetQueryPtr net_query);
};

// The runner inserts the complete function read from the pinned source here.
// @ACTUAL_ON_RESULT@

void require(bool condition, const char *message) {
  if (!condition) throw std::runtime_error(message);
}
NetQueryPtr query(int code = 0, std::string message = "", bool flag = true, uint64 id = 41) {
  return std::make_shared<Query>(Query{id, Result{Status{code, std::move(message)}, flag}, false});
}
using State = DeviceTokenManager::TokenInfo::State;

int main() {
  using Test = std::pair<const char *, std::function<void()>>;
  std::vector<Test> tests = {
    {"invalidated_reregister_is_terminal_and_persisted", [] {
      DeviceTokenManager manager;
      manager.on_result(query(400, "TOKEN_WAS_INVALIDATED"));
      auto &token = manager.tokens_[1];
      require(token.state == State::Sync && token.token.empty(), "invalidated token must become Sync and empty");
      require(manager.timeouts.empty(), "terminal invalidation must not schedule another request");
      require(manager.saves == 1 && manager.saved_slot == 1 && manager.saved_token.empty() && manager.saved_state == State::Sync,
              "only affected slot must be persisted empty (production save_info erases its key)");
      require(token.net_query_id == 0, "completed request must release query id");
      require(token.promise.error.code() == 400 && token.promise.completions == 1, "pending caller must receive original error once");
      require(manager.tokens_[2].token == "synthetic-invalid-token" && manager.tokens_[2].net_query_id == 41,
              "another token slot must remain intact");
    }},
    {"background_reregister_with_no_promise_is_terminal", [] {
      DeviceTokenManager manager; manager.tokens_[1].promise.pending = false;
      manager.on_result(query(400, "TOKEN_WAS_INVALIDATED"));
      require(manager.tokens_[1].token.empty() && manager.saves == 1 && manager.timeouts.empty(), "empty promise must not retain invalid token");
      require(manager.tokens_[1].promise.completions == 0, "absent caller must stay absent");
    }},
    {"old_query_cannot_clear_a_replacement_token", [] {
      DeviceTokenManager manager;
      manager.tokens_[1].token = "synthetic-new-token";
      manager.tokens_[1].net_query_id = 42;
      manager.tokens_[1].state = State::Register;
      auto old = query(400, "TOKEN_WAS_INVALIDATED"); manager.on_result(old);
      require(old->cleared && manager.tokens_[1].token == "synthetic-new-token", "stale completion must preserve replacement");
      require(manager.tokens_[1].net_query_id == 42 && manager.saves == 0 && manager.timeouts.empty(), "stale completion must have no transition");
    }},
    {"temporary_error_keeps_existing_retry", [] {
      DeviceTokenManager manager; manager.on_result(query(500, "INTERNAL_SERVER_ERROR"));
      require(manager.tokens_[1].state == State::Reregister && !manager.tokens_[1].token.empty(), "temporary error must preserve registration");
      require(manager.timeouts == std::vector<int>{1} && manager.saves == 0, "temporary retry behavior must remain unchanged");
    }},
    {"flood_wait_keeps_full_existing_deadline", [] {
      DeviceTokenManager manager; manager.on_result(query(429, "Too Many Requests: retry after 2640"));
      require(manager.timeouts == std::vector<int>{2640} && manager.saves == 0, "server delay must not shorten");
      require(!manager.tokens_[1].token.empty(), "flood wait must retain token");
    }},
    {"matching_message_with_different_code_is_not_terminal", [] {
      DeviceTokenManager manager; manager.on_result(query(500, "TOKEN_WAS_INVALIDATED"));
      require(manager.timeouts == std::vector<int>{1} && manager.saves == 0, "terminal classification needs exact code");
    }},
    {"different_400_message_is_not_terminal", [] {
      DeviceTokenManager manager; manager.on_result(query(400, "TOKEN_INVALID"));
      require(manager.timeouts == std::vector<int>{1} && manager.saves == 0, "terminal classification needs exact message");
    }},
    {"new_registration_failure_keeps_existing_transition", [] {
      DeviceTokenManager manager; manager.tokens_[1].state = State::Register;
      manager.on_result(query(400, "TOKEN_WAS_INVALIDATED"));
      require(manager.tokens_[1].state == State::Unregister && !manager.tokens_[1].token.empty(), "Register behavior is outside this patch");
      require(manager.saves == 1 && manager.timeouts.empty(), "Register failure persistence must remain unchanged");
    }},
    {"unregister_failure_keeps_existing_cleanup", [] {
      DeviceTokenManager manager; manager.tokens_[1].state = State::Unregister;
      manager.on_result(query(400, "TOKEN_WAS_INVALIDATED"));
      require(manager.tokens_[1].state == State::Sync && manager.tokens_[1].token.empty() && manager.saves == 1, "Unregister cleanup must remain unchanged");
    }},
    {"successful_reregister_preserves_token", [] {
      DeviceTokenManager manager; manager.on_result(query());
      require(manager.tokens_[1].state == State::Sync && !manager.tokens_[1].token.empty(), "success must preserve valid token");
      require(manager.saves == 1 && manager.timeouts.empty(), "success should persist without retry");
    }},
    {"false_result_keeps_existing_retry", [] {
      DeviceTokenManager manager; manager.on_result(query(0, "", false));
      require(manager.timeouts == std::vector<int>{1} && manager.saves == 0, "false result is outside terminal error branch");
    }}
  };
  int failures = 0;
  for (auto &test : tests) {
    try { test.second(); std::cout << "PASS " << test.first << '\n'; }
    catch (const std::exception &error) { ++failures; std::cout << "FAIL " << test.first << ": " << error.what() << '\n'; }
  }
  std::cout << "RESULT tests=" << tests.size() << " failures=" << failures << '\n';
  return failures ? 1 : 0;
}
