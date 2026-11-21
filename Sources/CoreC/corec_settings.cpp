// The settings schema behind nmr_corec.h.
#include <nmr/settings.h>

#include "nmr_corec.h"

namespace st = nmr::settings;

static_assert(NMR_SETTING_BOOL == static_cast<int>(st::Type::kBool));
static_assert(NMR_SETTING_INT == static_cast<int>(st::Type::kInt));
static_assert(NMR_SETTING_FLOAT == static_cast<int>(st::Type::kFloat));
static_assert(NMR_SETTING_CHOICE == static_cast<int>(st::Type::kChoice));
static_assert(NMR_SETTING_COLOR == static_cast<int>(st::Type::kColor));
static_assert(NMR_SETTING_TEXT == static_cast<int>(st::Type::kText));
static_assert(NMR_SCOPE_SHARED == static_cast<int>(st::Scope::kShared));
static_assert(NMR_SCOPE_APP == static_cast<int>(st::Scope::kApp));
static_assert(NMR_SCOPE_PLUGIN == static_cast<int>(st::Scope::kPlugin));

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
