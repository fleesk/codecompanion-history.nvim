---@class CodeCompanion.History
---@field opts    CodeCompanion.History.Opts
---@field storage CodeCompanion.History.Storage
---@field ui      CodeCompanion.History.UI
---@field new     fun(opts: CodeCompanion.History.Opts): CodeCompanion.History
local History = {}
local log = require("codecompanion._extensions.history.log")
local utils = require("codecompanion._extensions.history.utils")

--- Monkey patch to save some extra fields in the Chat instance
---@class CodeCompanion.History.ChatArgs: CodeCompanion.ChatArgs
---@field save_id string?
---@field cwd     string? Current working directory when chat was saved

---@class CodeCompanion.History.Chat: CodeCompanion.Chat
---@field opts CodeCompanion.History.ChatArgs

---@type CodeCompanion.History | nil
local history_instance

---@type CodeCompanion.History.Opts
local default_opts = {
  ---Keymap to open history from chat buffer (default: gh)
  keymap = "gh",
  ---Description for the history keymap (for which-key integration)
  keymap_description = "Browse saved chats",
  ---Keymap to save the current chat manually (when auto_save is disabled)
  save_chat_keymap = "sc",
  ---Description for the save chat keymap (for which-key integration)
  save_chat_keymap_description = "Save current chat",
  ---Save all chats by default (disable to save only manually using 'sc')
  auto_save = false,
  ---Automatically generate titles for new chats
  auto_generate_title = true,
  ---When chat is cleared with `gx` delete the chat from history
  delete_on_clearing_chat = false,
  ---Directory path to save the chats
  dir_to_save = vim.fn.stdpath("data") .. "/simplehist",
  ---Enable detailed logging for history extension
  enable_logging = false,
}

---@return CodeCompanion.History
function History.new(opts)
  local history = setmetatable({}, {
    __index = History,
  })
  history.opts = opts
  history.storage = require("codecompanion._extensions.history.storage").new(opts)
  history.ui = require("codecompanion._extensions.history.ui").new(opts, history.storage)

  -- Setup commands
  history:_create_commands()
  history:_setup_autocommands()
  history:_setup_keymaps()
  return history --[[@as CodeCompanion.History]]
end

function History:_create_commands()
  vim.api.nvim_create_user_command("CodeCompanionHistory", function()
    self.ui:open_saved_chats()
  end, {
    desc = "Open saved chats",
  })
end

function History:_setup_autocommands()
  local group = vim.api.nvim_create_augroup("CodeCompanionHistory", { clear = true })
  -- util.fire("ChatCreated", { bufnr = self.bufnr, from_prompt_library = self.from_prompt_library, id = self.id })
  vim.api.nvim_create_autocmd("User", {
    pattern = "CodeCompanionChatCreated",
    group = group,
    callback = vim.schedule_wrap(function(opts)
      -- data = {
      -- bufnr = 5,
      -- from_prompt_library = false,
      -- id = 7463137
      -- },
      log:trace("Chat created event received")
      local chat_module = require("codecompanion.interactions.chat")
      local bufnr = opts.data.bufnr
      local chat = chat_module.buf_get_chat(bufnr) --[[@as CodeCompanion.History.Chat]]

      -- Check if custom save_id exists, else generate
      if not chat.opts.save_id then
        chat.opts.save_id = tostring(os.time())
        log:trace("Generated new save_id: %s", chat.opts.save_id)
      end

      -- self:_subscribe_to_chat(chat)
    end),
  })
  vim.api.nvim_create_autocmd("User", {
    pattern = "CodeCompanion*Finished",
    group = group,
    callback = vim.schedule_wrap(function(opts)
      if not self.opts.auto_save then
        return
      end
      if opts.match == "CodeCompanionRequestFinished" or opts.match == "CodeCompanionToolsFinished" then
        log:trace("Chat %s event received for %s", opts.match, opts.data.interaction)
        if opts.match == "CodeCompanionRequestFinished" and opts.data.interaction ~= "chat" then
          return log:trace("Skipping RequestFinished event received for non-chat interaction")
        end
        local chat_module = require("codecompanion.interactions.chat")
        local bufnr = opts.data.bufnr
        if not bufnr then
          return log:trace("No bufnr found in event data")
        end
        local chat = chat_module.buf_get_chat(bufnr) --[[@as CodeCompanion.History.Chat]]
        if chat then
          self.storage:save_chat(chat)
        end
      end
    end),
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "CodeCompanionChatSubmitted",
    group = group,
    callback = vim.schedule_wrap(function(opts)
      log:trace("Chat submitted event received")
      local chat_module = require("codecompanion.interactions.chat")
      local bufnr = opts.data.bufnr
      local chat = chat_module.buf_get_chat(bufnr) --[[@as CodeCompanion.History.Chat]]
      if not chat then
        return
      end

      if self.opts.auto_save then
        self.storage:save_chat(chat)
      end
    end),
  })

  vim.api.nvim_create_autocmd("User", {
    pattern = "CodeCompanionChatCleared",
    group = group,
    callback = vim.schedule_wrap(function(opts)
      log:trace("Chat cleared event received")

      local chat_module = require("codecompanion.interactions.chat")
      local bufnr = opts.data.bufnr
      local chat = chat_module.buf_get_chat(bufnr) --[[@as CodeCompanion.History.Chat]]
      if not chat then
        return
      end
      if self.opts.delete_on_clearing_chat then
        log:trace("Deleting cleared chat from storage: %s", chat.opts.save_id)
        self.storage:delete_chat(chat.opts.save_id)
      end

      -- Reset chat state
      chat.opts.save_id = tostring(os.time())
      log:trace("Generated new save_id after clear: %s", chat.opts.save_id)
    end),
  })
end

function History:_setup_keymaps()
  local function form_modes(v)
    if type(v) == "string" then
      return { n = v }
    end
    return v
  end

  local keymaps = {
    ["Saved Chats"] = {
      modes = form_modes(self.opts.keymap),
      description = self.opts.keymap_description,
      callback = function(_)
        self.ui:open_saved_chats()
      end,
    },
    ["Save Current Chat"] = {
      modes = form_modes(self.opts.save_chat_keymap),
      description = self.opts.save_chat_keymap_description,
      callback = function(chat)
        if not chat then
          return
        end
        self.storage:save_chat(chat)
        log:debug("Saved current chat")
      end,
    },
  }

  local cc_config = require("codecompanion.config")
  -- Add all keymaps to codecompanion
  for name, keymap in pairs(keymaps) do
    cc_config.interactions.chat.keymaps[name] = keymap
  end
end

---@type CodeCompanion.Extension
return {
  ---@param opts CodeCompanion.History.Opts
  setup = function(opts)
    if not history_instance then
      -- Initialize logging first
      opts = vim.tbl_deep_extend("force", default_opts, opts or {})
      log.setup_logging(opts.enable_logging)
      history_instance = History.new(opts)
      log:debug("History extension setup successfully")
    end
  end,
  exports = {
    ---Get the base path of the storage
    ---@return string?
    get_location = function()
      if not history_instance then
        return
      end
      return history_instance.storage:get_location()
    end,
    ---Save a chat to storage falling back to the last chat if none is provided
    ---@param chat? CodeCompanion.History.Chat
    save_chat = function(chat)
      if not history_instance then
        return
      end
      history_instance.storage:save_chat(chat)
    end,
    ---Browse chats
    browse_chats = function()
      if not history_instance then
        return
      end
      history_instance.ui:open_saved_chats()
    end,
    --- Loads chats metadata from the index
    ---@return table<string, CodeCompanion.History.ChatIndexData>
    get_chats = function()
      if not history_instance then
        return {}
      end
      return history_instance.storage:get_chats()
    end,
    --- Load a specific chat
    ---@param save_id string ID from chat.opts.save_id to retreive the chat
    ---@return CodeCompanion.History.ChatData?
    load_chat = function(save_id)
      if not history_instance then
        return
      end
      return history_instance.storage:load_chat(save_id)
    end,
    ---Delete a chat
    ---@param save_id string ID from chat.opts.save_id to retreive the chat
    ---@return boolean
    delete_chat = function(save_id)
      if not history_instance then
        return false
      end
      return history_instance.storage:delete_chat(save_id)
    end,
  },
  --for testing
  History = History,
}
