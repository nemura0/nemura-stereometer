// The settings schema and setting values behind nmr_corec.h.
#include <nmr/settings.h>
#include <nmr/settings_json.h>

#include <cstdlib>
#include <optional>
#include <string_view>

#include "corec_internal.h"
#include "nmr_corec.h"

namespace st = nmr::settings;
using nmr::corec::guarded;
using nmr::corec::idAt;

static_assert(NMR_SETTING_BOOL == static_cast<int>(st::Type::kBool));
static_assert(NMR_SETTING_INT == static_cast<int>(st::Type::kInt));
static_assert(NMR_SETTING_FLOAT == static_cast<int>(st::Type::kFloat));
static_assert(NMR_SETTING_CHOICE == static_cast<int>(st::Type::kChoice));
static_assert(NMR_SETTING_COLOR == static_cast<int>(st::Type::kColor));
static_assert(NMR_SETTING_TEXT == static_cast<int>(st::Type::kText));
static_assert(NMR_SCOPE_SHARED == static_cast<int>(st::Scope::kShared));
static_assert(NMR_SCOPE_APP == static_cast<int>(st::Scope::kApp));
static_assert(NMR_SCOPE_PLUGIN == static_cast<int>(st::Scope::kPlugin));
static_assert(NMR_CHANGE_SET == static_cast<int>(st::Change::kSet));
static_assert(NMR_CHANGE_ADJUSTED == static_cast<int>(st::Change::kAdjusted));
static_assert(NMR_CHANGE_REJECTED == static_cast<int>(st::Change::kRejected));

namespace {

const st::Spec* entryAt(uint32_t index) {
  const std::span<const st::Spec> schema = st::schema();
  return index < schema.size() ? &schema[index] : nullptr;
}

const st::Choice* choiceAt(uint32_t index, uint32_t choice) {
  const st::Spec* entry = entryAt(index);
  return entry != nullptr && choice < entry->choices.size() ? &entry->choices[choice] : nullptr;
}

}  // namespace

uint32_t nmr_settings_count(void) { return static_cast<uint32_t>(st::schema().size()); }

bool nmr_settings_spec(uint32_t index, nmr_setting_spec* spec) {
  const st::Spec* entry = entryAt(index);
  if (entry == nullptr || spec == nullptr) return false;
  *spec = nmr_setting_spec{
      .key = entry->key,
      .label = entry->label,
      .unit = entry->unit,
      .group = static_cast<uint32_t>(entry->group),
      .type = static_cast<nmr_setting_type>(entry->type),
      .scope = static_cast<nmr_setting_scope>(entry->scope),
      .preset = entry->preset,
      .min = entry->min,
      .max = entry->max,
      .step = entry->step,
      .default_value = entry->default_value,
      .default_text = entry->default_text,
      .max_length = entry->max_length,
      .choice_count = static_cast<uint32_t>(entry->choices.size()),
      .stop_count = static_cast<uint32_t>(entry->stops.size()),
  };
  return true;
}

const char* nmr_settings_choice_key(uint32_t index, uint32_t choice) {
  const st::Choice* found = choiceAt(index, choice);
  return found != nullptr ? found->key : nullptr;
}

const char* nmr_settings_choice_label(uint32_t index, uint32_t choice) {
  const st::Choice* found = choiceAt(index, choice);
  return found != nullptr ? found->label : nullptr;
}

bool nmr_settings_stop(uint32_t index, uint32_t stop, const char** label, double* value) {
  const st::Spec* entry = entryAt(index);
  if (entry == nullptr || stop >= entry->stops.size()) return false;
  if (label != nullptr) *label = entry->stops[stop].label;
  if (value != nullptr) *value = entry->stops[stop].value;
  return true;
}

uint32_t nmr_settings_group_count(void) { return static_cast<uint32_t>(st::kGroupCount); }

const char* nmr_settings_group_key(uint32_t group) {
  return group < st::kGroupCount ? st::group(static_cast<st::Group>(group)).key : nullptr;
}

const char* nmr_settings_group_label(uint32_t group) {
  return group < st::kGroupCount ? st::group(static_cast<st::Group>(group)).label : nullptr;
}

int32_t nmr_settings_index(const char* key) {
  if (key == nullptr) return -1;
  const std::optional<st::Id> id = st::find(key);
  return id ? static_cast<int32_t>(*id) : -1;
}

// ---- Setting values ----------------------------------------------------------------------------

nmr_settings* nmr_settings_create(void) {
  return guarded<nmr_settings*>(nullptr, [] { return new nmr_settings{}; });
}

nmr_settings* nmr_settings_copy(const nmr_settings* settings) {
  return settings != nullptr ? nmr::corec::adopt(settings->value) : nullptr;
}

void nmr_settings_destroy(nmr_settings* settings) { delete settings; }

bool nmr_settings_equal(const nmr_settings* a, const nmr_settings* b) {
  return a != nullptr && b != nullptr && a->value == b->value;
}

double nmr_settings_number(const nmr_settings* settings, uint32_t index) {
  const std::optional<st::Id> id = idAt(index);
  return settings != nullptr && id ? settings->value.number(*id) : 0;
}

const char* nmr_settings_text(const nmr_settings* settings, uint32_t index) {
  const std::optional<st::Id> id = idAt(index);
  if (settings == nullptr || !id) return nullptr;
  return settings->value.text(*id).c_str();  // "" for entries that are not text
}

nmr_change nmr_settings_set_number(nmr_settings* settings, uint32_t index, double value) {
  const std::optional<st::Id> id = idAt(index);
  if (settings == nullptr || !id) return NMR_CHANGE_REJECTED;
  return static_cast<nmr_change>(settings->value.setNumber(*id, value));
}

nmr_change nmr_settings_set_choice(nmr_settings* settings, uint32_t index, const char* key) {
  const std::optional<st::Id> id = idAt(index);
  if (settings == nullptr || !id || key == nullptr) return NMR_CHANGE_REJECTED;
  return static_cast<nmr_change>(settings->value.setChoice(*id, key));
}

nmr_change nmr_settings_set_text(nmr_settings* settings, uint32_t index, const char* text) {
  const std::optional<st::Id> id = idAt(index);
  if (settings == nullptr || !id || text == nullptr) return NMR_CHANGE_REJECTED;
  return guarded(NMR_CHANGE_REJECTED, [&] {
    return static_cast<nmr_change>(settings->value.setText(*id, text));
  });
}

void nmr_settings_reset(nmr_settings* settings, uint32_t index) {
  const std::optional<st::Id> id = idAt(index);
  if (settings == nullptr || !id) return;
  guarded(false, [&] {
    settings->value.reset(*id);
    return true;
  });
}

// ---- Settings as JSON --------------------------------------------------------------------------

static_assert(NMR_JSON_OK == static_cast<int>(st::Status::kOk));
static_assert(NMR_JSON_NOT_JSON == static_cast<int>(st::Status::kNotJson));
static_assert(NMR_JSON_NOT_SETTINGS == static_cast<int>(st::Status::kNotSettings));
static_assert(NMR_JSON_TOO_LARGE == static_cast<int>(st::Status::kTooLarge));
static_assert(NMR_JSON_UNREADABLE == static_cast<int>(st::Status::kUnreadable));

char* nmr_settings_encode(const nmr_settings* settings) {
  if (settings == nullptr) return nullptr;
  return guarded<char*>(nullptr,
                        [&] { return nmr::corec::duplicate(st::encodeState(settings->value)); });
}

nmr_settings* nmr_settings_decode(const char* json, size_t length, nmr_json_report* report) {
  // What a failed allocation leaves.
  if (report != nullptr) *report = nmr::corec::toC(st::Report{.status = st::Status::kUnreadable});
  const std::string_view text =
      json != nullptr ? std::string_view(json, length) : std::string_view();
  return guarded<nmr_settings*>(nullptr, [&] {
    st::Report found;
    auto* settings = new nmr_settings{st::decodeState(text, found)};
    if (report != nullptr) *report = nmr::corec::toC(found);
    return settings;
  });
}

void nmr_string_free(char* text) { std::free(text); }
