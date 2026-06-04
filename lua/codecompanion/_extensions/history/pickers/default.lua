local utils = require("codecompanion._extensions.history.utils")

---@class CodeCompanion.History.PickerConfig
---@field items            CodeCompanion.History.EntryItem[] Array of items to display
---@field handlers         CodeCompanion.History.UIHandlers  Action handlers
---@field current_item_id? string                            Current item ID for highlighting
---@field title            string                            Picker title

---@class CodeCompanion.History.DefaultPicker
---@field config CodeCompanion.History.PickerConfig
local DefaultPicker = {}
DefaultPicker.__index = DefaultPicker

---@param config CodeCompanion.History.PickerConfig
---@return CodeCompanion.History.DefaultPicker
function DefaultPicker:new(config)
  local base = setmetatable({}, self)
  self.config = config
  return base
end

function DefaultPicker:browse()
  vim.ui.select(self.config.items, {
    prompt = self.config.title,
    format_item = function(item)
      return self:format_entry(item)
    end,
  }, function(selected)
    if selected then
      self.config.handlers.on_select(selected)
    end
  end)
end

--- Get the unique ID for an item
---@param item table
---@return string
function DefaultPicker:get_item_id(item)
  return item.save_id
end

--- Get the display title for an item
---@param item table
---@return string
function DefaultPicker:get_item_title(item)
  return item.title or "Untitled"
end

--- Check if an item is the current item
---@param item table
---@return boolean
function DefaultPicker:is_current_item(item)
  return self.config.current_item_id == self:get_item_id(item)
end

--- Get the item name for user messages (singular)
---@return string
function DefaultPicker:get_item_name_singular()
  return "chat"
end

--- Get the item name for user messages (plural)
---@return string
function DefaultPicker:get_item_name_plural()
  return "chats"
end

--- Generic format entry method that dispatches based on item type
---@param entry CodeCompanion.History.EntryItem Entry from the index
---@return string formatted_display
function DefaultPicker:format_entry(entry)
  local parts = {}

  -- Current chat indicator
  local is_current = self:is_current_item(entry)
  local chevron = ""
  table.insert(parts, is_current and chevron or " ")

  -- Title
  table.insert(parts, self:get_item_title(entry))

  if entry.token_estimate then
    local tokens = entry.token_estimate
    table.insert(parts, string.format("(~%.1fk)", tokens / 1000))
  end

  -- Relative time
  local icon = " "
  table.insert(parts, icon .. utils.format_relative_time(entry.updated_at) .. "")

  return table.concat(parts, " ")
end

return DefaultPicker
