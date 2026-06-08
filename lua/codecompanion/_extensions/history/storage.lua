---@class CodeCompanion.History.Storage
---@field base_path  string Base directory path
---@field index_path string Path to index file
---@field chats_dir  string Path to chats directory
local Storage = {}

local log = require("codecompanion._extensions.history.log")
local utils = require("codecompanion._extensions.history.utils")

function Storage.new(opts)
  local self = setmetatable({}, {
    __index = Storage,
  })

  self.base_path = opts.dir_to_save:gsub("/+$", "")
  self.index_path = self.base_path .. "/index.json"
  self.chats_dir = self.base_path .. "/chats"
  log:trace("Initializing storage with base path: %s", self.base_path)
  -- Ensure storage directories exist
  self:_ensure_storage_dirs()

  return self --[[@as CodeCompanion.History.Storage]]
end

--- Get the base path of the storage
---@return string
function Storage:get_location()
  return self.base_path
end

function Storage:_ensure_storage_dirs()
  local Path = require("plenary.path")

  -- Create base directory
  local base_dir = Path:new(self.base_path)
  if not base_dir:exists() then
    log:trace("Creating base directory: %s", self.base_path)
    base_dir:mkdir({ parents = true })
  end

  -- Create chats directory
  local chats_dir = Path:new(self.chats_dir)
  if not chats_dir:exists() then
    log:trace("Creating chats directory: %s", self.chats_dir)
    chats_dir:mkdir({ parents = true })
  end

  -- Initialize index file if it doesn't exist
  local index_path = Path:new(self.index_path)
  if not index_path:exists() then
    log:trace("Initializing empty index file: %s", self.index_path)
    -- Initialize with empty object, not array, since we use it as a key-value store
    local empty_index = vim.empty_dict()
    local result = utils.write_json(self.index_path, empty_index)
    if not result.ok then
      log:error("Failed to initialize index file: %s", result.error)
    end
  end
end

---@param chat_data CodeCompanion.History.ChatData
---@return { ok: boolean, error: string | nil }
function Storage:_save_chat_to_file(chat_data)
  local chat_path = self.chats_dir .. "/" .. chat_data.save_id .. ".json"
  log:trace("Saving chat to file: %s", chat_path)
  return utils.write_json(chat_path, chat_data)
end

---@param chat_data CodeCompanion.History.ChatData
---@return { ok: boolean, error: string | nil }
function Storage:_update_index_entry(chat_data)
  log:trace("Updating index entry for chat: %s", chat_data.save_id)
  -- Read current index
  local index_result = utils.read_json(self.index_path)
  if not index_result.ok then
    return { ok = false, error = "Failed to read index: " .. index_result.error }
  end

  -- Ensure we have a table to work with
  local index = index_result.data or {}

  -- Calculate message count and token estimate
  local message_count = #(chat_data.messages or {})
  local total_chars = 0
  for _, msg in ipairs(chat_data.messages or {}) do
    total_chars = total_chars + #(msg.content or "")
  end
  local token_estimate = math.floor(total_chars / 4)

  -- Update index with enhanced metadata
  index[chat_data.save_id] = {
    save_id = chat_data.save_id,
    title = chat_data.title,
    updated_at = chat_data.updated_at,
    model = chat_data.settings and chat_data.settings.model or "unknown",
    adapter = chat_data.adapter or "unknown",
    message_count = message_count,
    token_estimate = token_estimate,
    cwd = chat_data.cwd,
    project_root = chat_data.project_root,
  }

  -- Write updated index
  return utils.write_json(self.index_path, utils.remove_functions(index))
end

--- Load all chats from storage (index only)
---@return table<string, CodeCompanion.History.ChatIndexData>
function Storage:get_chats()
  log:trace("Loading chat index")
  local result = utils.read_json(self.index_path)
  if not result.ok then
    if result.error:match("does not exist") then
      log:trace("Index file does not exist, initializing storage")
      self:_ensure_storage_dirs()
      return {}
    else
      log:error("Failed to read chat index: %s", result.error)
      return {}
    end
  end

  local all_chats = result.data or {}

  return all_chats
end

--- Load a specific chat by ID
---@param id string
---@return CodeCompanion.History.ChatData | nil
function Storage:load_chat(id)
  local chat_path = self.chats_dir .. "/" .. id .. ".json"
  log:trace("Loading chat from: %s", chat_path)
  local result = utils.read_json(chat_path)

  if not result.ok then
    if not result.error:match("does not exist") then
      log:error("Failed to load chat: %s", result.error)
    end
    return nil
  end

  return result.data --[[@as CodeCompanion.History.ChatData]]
end

--- Validate chat object for required fields and structure
---@param chat table
---@return boolean, string?
local function validate_chat_object(chat)
  if not chat then
    return false, "chat object is nil"
  end
  if type(chat) ~= "table" then
    return false, "chat must be a table"
  end
  if type(chat.opts) ~= "table" then
    return false, "chat.opts must be a table"
  end
  if type(chat.opts.save_id) ~= "string" then
    return false, "chat.opts.save_id must be a string"
  end
  -- Check for path traversal characters in save_id
  if chat.opts.save_id:match("[/\\]") then
    return false, "invalid characters in save_id"
  end
  -- Validate messages structure if present
  if chat.messages ~= nil then
    if type(chat.messages) ~= "table" then
      return false, "messages must be a table"
    end
    for i, msg in ipairs(chat.messages) do
      if type(msg) ~= "table" then
        return false, string.format("message %d must be a table", i)
      end
      if msg.role ~= nil and type(msg.role) ~= "string" then
        return false, string.format("message %d role must be a string", i)
      end
    end
  end
  return true
end

--- Save a chat to storage falling back to the last chat if none is provided
---@param chat? CodeCompanion.History.Chat
function Storage:save_chat(chat)
  if not chat then
    chat = require("codecompanion").last_chat() --[[@as CodeCompanion.History.Chat]]
    if not chat then
      return
    end
  end

  -- Validate chat object structure
  local valid, err = validate_chat_object(chat)
  if not valid then
    log:error("Cannot save chat: %s", err)
    return
  end

  log:trace("Saving chat: %s", chat.opts.save_id)
  local cwd = chat.opts.cwd or vim.fn.getcwd()
  -- Create chat data object requiring valid types
  ---@type CodeCompanion.History.ChatData
  local chat_data = {
    acp_session_id = chat.acp_connection and chat.acp_connection.session_id,
    acp_command = chat.adapter and chat.adapter.commands and chat.adapter.commands.selected,
    title = chat.title or "Untitled",
    save_id = chat.opts.save_id,
    messages = chat.messages or {},
    settings = chat.settings or {},
    adapter = {
      type = chat.adapter and chat.adapter.type or "http",
      name = chat.adapter and chat.adapter.name or "unknown",
      -- formatted_name = chat.adapter and chat.adapter.formatted_name or "unknown",
      model = chat.adapter and chat.adapter.model and chat.adapter.model.name,
      commands = chat.adapter and chat.adapter.commands,
      -- defaults = chat.adapter and chat.adapter.defaults,
      -- parameters = chat.adapter and chat.adapter.parameters,
      -- roles = chat.adapter and chat.adapter.roles,
    },
    updated_at = os.time(),
    context_items = chat.context_items or {},
    schemas = (chat.tool_registry and chat.tool_registry.schemas) or {},
    in_use = (chat.tool_registry and chat.tool_registry.in_use) or {},
    cycle = chat.cycle or 1,
    cwd = cwd,
    project_root = utils.find_project_root(cwd),
  }

  -- Save chat to file
  local save_result = self:_save_chat_to_file(utils.remove_functions(chat_data))
  if not save_result.ok then
    log:error("Failed to save chat: %s", save_result.error)
    return
  end

  -- Update index
  local index_result = self:_update_index_entry(chat_data)
  if not index_result.ok then
    log:error("Failed to update index: %s", index_result.error)
  end
end

--- Delete a chat from storage
---@param id string
---@return boolean
function Storage:delete_chat(id)
  if not id then
    log:error("Cannot delete chat: missing id")
    return false
  end

  log:debug("Deleting chat: %s", id)
  -- Delete the chat file
  local chat_path = self.chats_dir .. "/" .. id .. ".json"
  local delete_result = utils.delete_file(chat_path)
  if not delete_result.ok then
    log:error("Failed to delete chat file: %s", delete_result.error)
  end

  -- Remove from index
  local index_result = utils.read_json(self.index_path)
  if not index_result.ok then
    log:error("Failed to read index for deletion: %s", index_result.error)
    return false
  end

  -- Ensure we have a table to work with
  local index = index_result.data or {}

  -- Remove entry from index
  index[id] = nil

  -- Save updated index
  local write_result = utils.write_json(self.index_path, index)
  if not write_result.ok then
    log:error("Failed to update index after deletion: %s", write_result.error)
    return false
  end
  return true
end

--- Get the most recently updated chat from storage
---@return CodeCompanion.History.ChatData | nil
function Storage:get_last_chat()
  log:debug("Getting most recent chat")
  local index = self:get_chats()
  if vim.tbl_isempty(index) then
    return nil
  end

  -- Find the most recently updated chat
  local most_recent = nil
  local most_recent_time = 0

  for id, chat_meta in pairs(index) do
    if chat_meta.updated_at and chat_meta.updated_at > most_recent_time then
      most_recent = id
      most_recent_time = chat_meta.updated_at
    end
  end

  -- If we found a recent chat, load and return it
  if most_recent then
    log:trace("Found most recent chat: %s", most_recent)
    return self:load_chat(most_recent)
  end

  return nil
end

return Storage
