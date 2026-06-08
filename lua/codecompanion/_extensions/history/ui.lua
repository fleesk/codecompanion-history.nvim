local config = require("codecompanion.config")
local log = require("codecompanion._extensions.history.log")

---@class CodeCompanion.History.UI
---@field storage CodeCompanion.History.Storage
local UI = {}

---@param opts    CodeCompanion.History.Opts
---@param storage CodeCompanion.History.Storage
---@return CodeCompanion.History.UI
function UI.new(opts, storage)
  local self = setmetatable({}, {
    __index = UI,
  })

  self.storage = storage

  log:trace("Initialized UI")
  return self --[[@as CodeCompanion.History.UI]]
end

--- Format items for display based on type
---@param items_data table<string, CodeCompanion.History.ChatIndexData> Raw items from storage
---@param storage    CodeCompanion.History.Storage                      Storage instance for getting summaries
---@return CodeCompanion.History.EntryItem[] Formatted items
local function format_items(items_data, storage)
  local items = {}

  for _, chat_item in pairs(items_data) do
    local save_id = chat_item.save_id
    table.insert(
      items,
      vim.tbl_extend("keep", {
        save_id = save_id,
        name = chat_item.title or save_id,
        updated_at = chat_item.updated_at or 0,
      }, chat_item)
    )
  end
  -- Sort items by updated_at in descending order
  table.sort(items, function(a, b)
    return a.updated_at > b.updated_at
  end)

  return items
end

--- Generic method to open items (chats or summaries)
---@param items_data       table<string, CodeCompanion.History.ChatIndexData> Raw items from storage
---@param handlers         CodeCompanion.History.UIHandlers                   Handlers for item actions
---@param current_item_id? string                                             Current item ID for highlighting
function UI:_open_items(items_data, handlers, current_item_id)
  log:trace("Opening chats browser")

  if vim.tbl_isempty(items_data) then
    log:trace("No chats found")
    vim.notify("No chats found", vim.log.levels.INFO)
    return
  end

  -- Format the items for display
  local items = format_items(items_data, self.storage)
  log:trace("Loaded %d chats", #items)

  -- Load the configured picker module
  log:trace("Using picker")

  local resolved_picker = require("codecompanion._extensions.history.pickers.default")

  resolved_picker
    :new({
      items = items,
      handlers = handlers,
      current_item_id = current_item_id,
      title = "Saved Chats",
    })
    :browse()
end

function UI:open_saved_chats()
  local codecompanion = require("codecompanion")
  local last_chat = codecompanion.last_chat() --[[@as CodeCompanion.History.Chat?]]

  self:_open_items(self.storage:get_chats(), {
    on_open = function()
      log:trace("Opening saved chats picker")
      self:open_saved_chats()
    end,
    ---@param chat_data CodeCompanion.History.ChatData
    ---@return string[] lines
    on_preview = function(chat_data)
      -- Load full chat data for preview
      local full_chat = self.storage:load_chat(chat_data.save_id)
      if full_chat then
        return self:_get_preview_lines(full_chat)
      else
        log:warn("Failed to load chat data for preview: %s", chat_data.save_id)
        return { "Chat data not available" }
      end
    end,
    ---@param chat_data CodeCompanion.History.ChatData
    on_select = function(chat_data)
      self:_handle_on_select(chat_data.save_id)
    end,
  }, last_chat and last_chat.opts.save_id)
end

---@param save_id string
function UI:_handle_on_select(save_id)
  local codecompanion = require("codecompanion")
  log:trace("Selected chat: %s", save_id)
  local chat_module = require("codecompanion.interactions.chat")
  local opened_chats = chat_module.buf_get_chat()
  local active_chat = codecompanion.last_chat()

  for _, data in ipairs(opened_chats) do
    if data.chat.opts.save_id == save_id then
      if (active_chat and not active_chat.ui:is_active()) or active_chat ~= data.chat then
        if active_chat and active_chat.ui:is_active() then
          active_chat.ui:hide()
        end
        data.chat.ui:open()
      else
        log:trace("Chat already open: %s", save_id)
        vim.notify("Chat already open", vim.log.levels.INFO)
      end
      return
    end
  end

  -- Load full chat data when selecting
  local full_chat = self.storage:load_chat(save_id)
  if full_chat then
    self:create_chat(full_chat)
  else
    log:error("Failed to load chat: %s", save_id)
    vim.notify("Failed to load chat", vim.log.levels.ERROR)
  end
end

--- Creates a new chat from the given chat data restoring what it can along with the adapter, settings. If adapter is not found, ask user to select another adapter. If adapter is found but model is not available, uses the adapter's default model.
---@param chat_data? CodeCompanion.History.ChatData
---@return CodeCompanion.History.Chat?
function UI:create_chat(chat_data)
  log:trace("Creating new chat from saved data")
  chat_data = chat_data or {}
  local messages = chat_data.messages or {}
  local save_id = chat_data.save_id
  local title = chat_data.title
  local acp_session_id = chat_data.acp_session_id -- both nil for http
  local acp_command = chat_data.acp_command

  messages = messages or {}
  local last_msg = messages[#messages]

  -- HACK: Ensure last message is from user to show header
  if last_msg and (last_msg.role ~= "user" or (last_msg.role == "user" and (last_msg.opts or {}).visible == false)) then
    log:trace("Adding empty user message to ensure header visibility")
    table.insert(messages, {
      role = "user",
      content = "",
      opts = { visible = true },
    })
  end
  local context_utils = require("codecompanion.utils.context")
  local last_active_buffer = require("codecompanion._extensions.history.utils").get_editor_info().last_active
  local context = context_utils.get(last_active_buffer and last_active_buffer.bufnr or nil)
  ---@param adapter  table
  ---@param settings table?
  local function _create_chat(adapter, settings)
    local complete_adapter = {}
    if adapter.type == "acp" then
      local config_adapter = config.adapters.acp[adapter.name]
      complete_adapter = vim.tbl_deep_extend("keep", adapter, config_adapter)
      complete_adapter = require("codecompanion.adapters").resolve(complete_adapter)
    else
      complete_adapter = adapter
    end
    local chat = require("codecompanion.interactions.chat").new({
      save_id = save_id,
      acp_session_id = acp_session_id,
      acp_command = acp_command,
      messages = messages,
      buffer_context = context,
      settings = settings,
      adapter = complete_adapter, -- [[@as CodeCompanion.Adapter]]
      title = title,
      --INFO: No need to ignore system prompt here, thanks to oli we don't add system messages with same tag (`from_config`) twice.
      -- This also fixes `gx` removing the system prompt from the chat if we pass `ignore_system_prompt = true`
      -- ignore_system_prompt = true,
    }) --[[@as CodeCompanion.History.Chat]]
    -- Handle both old (refs) and new (context_items) storage formats
    local stored_context_items = chat_data.context_items or chat_data.refs or {}
    local chat_context_items = chat.context_items or {}
    for _, item in ipairs(stored_context_items) do
      -- Avoid adding duplicates related to #48
      local is_duplicate = vim.tbl_contains(chat_context_items, function(chat_item)
        return chat_item.id == item.id
      end, { predicate = true })
      if not is_duplicate then
        chat.context:add(item)
      end
    end
    chat.tool_registry.schemas = chat_data.schemas or {}
    chat.tool_registry.in_use = chat_data.in_use or {}
    chat.cycle = chat_data.cycle or 1
    chat.opts.title_refresh_count = chat_data.title_refresh_count or 0
    log:trace("Successfully created chat with save_id: %s", save_id or "N/A")
    return chat
  end
  local adapter = chat_data.adapter
  local settings = chat_data.settings or {}
  if adapter then
    local found, resolved_adapter = pcall(require("codecompanion.adapters").resolve, adapter)
    -- If the adapter is not found, we need to change it. If found, we need to check if the model is available
    if not found then
      vim.notify(
        string.format("Adapter '%s' not available, please select another adapter", adapter),
        vim.log.levels.WARN
      )
      return self:_change_adapter(_create_chat)
    else
      if resolved_adapter.type ~= "acp" then
        local saved_model = settings.model
        if saved_model then
          local available_models = resolved_adapter.schema.model.choices
          -- INFO:Skipping if models is a function
          -- if type(available_models) == "function" then
          -- vim.notify("Please wait while we fetch the avaiable models in " .. adapter)
          -- available_models = available_models(resolved_adapter)
          -- end
          if type(available_models) == "table" then
            available_models = vim
              .iter(available_models)
              :map(function(model, value)
                if type(model) == "string" then
                  return model
                else
                  return value -- This is for the table entry case
                end
              end)
              :totable()
            local has_model = vim.tbl_contains(available_models, saved_model)
            if not has_model then
              vim.notify(
                string.format("Model '%s' is not available in '%s' adapter, using default model.", saved_model, adapter)
              )
              return _create_chat(adapter, nil)
              -- INFO: this results in rare errors where the model opts differ from one model to another model.
              -- return self:_change_model(available_models, function(model)
              -- settings.model = model
              -- create_chat(adapter, nil)
              -- end)
            end
          end
        end
      end
    end
  end
  return _create_chat(adapter, settings)
end

--- [[Most of the code is copied from codecompanion/interactions/chat/ui.lua]]
--- Retrieve the lines to be displayed in the preview window
---@param chat_data CodeCompanion.History.ChatData
function UI:_get_preview_lines(chat_data)
  local lines = {}
  local function spacer()
    table.insert(lines, "")
  end
  local function set_header(tbl, role)
    local header = "## " .. role
    table.insert(tbl, header)
    table.insert(tbl, "")
  end
  local system_role = config.constants.SYSTEM_ROLE
  local user_role = config.constants.USER_ROLE
  local assistant_role = config.constants.LLM_ROLE
  local last_role
  local last_set_role
  local function render_context_items(context_items)
    if vim.tbl_isempty(context_items) then
      return
    end
    table.insert(lines, "> Context:")
    local icons_path = config.display.chat.icons
    local icons = {
      pinned = icons_path.pinned_buffer or icons_path.buffer_pin,
      watched = icons_path.watched_buffer or icons_path.buffer_watch,
    }
    for _, item in pairs(context_items) do
      if not item or (item.opts and item.opts.visible == false) then
        goto continue
      end
      if item.opts and item.opts.pinned then
        table.insert(lines, string.format("> - %s%s", icons.pinned, item.id))
      elseif item.opts and item.opts.watched then
        table.insert(lines, string.format("> - %s%s", icons.watched, item.id))
      else
        table.insert(lines, string.format("> - %s", item.id))
      end
      ::continue::
    end
    if #lines == 1 then
      -- no context items added
      return
    end
    table.insert(lines, "")
  end
  local function add_messages_to_buf(msgs)
    for i, msg in ipairs(msgs) do
      if (msg.role ~= system_role) and not (msg.opts and msg.opts.visible == false) then
        -- For workflow prompts: Ensure main user role doesn't get spaced
        if i > 1 and last_role ~= msg.role and msg.role ~= user_role then
          spacer()
        end

        if msg.role == user_role and last_set_role ~= user_role then
          if last_set_role ~= nil then
            spacer()
          end
          set_header(lines, "  User")
        end
        if msg.role == assistant_role and last_set_role ~= assistant_role then
          set_header(lines, "  Assistant")
        end

        if msg.opts and msg.opts.tag == "tool_output" then
          table.insert(lines, "### Tool Output")
          table.insert(lines, "")
        end

        local trimempty = not (msg.role == "user" and msg.content == "")
        local display_content = msg.content or ""
        -- INFO: For anthropic adapter, the tool output is in content.content
        if type(display_content) == "table" then
          if type(msg.content.content) == "string" then
            display_content = msg.content.content
          else
            display_content = "[Message Cannot Be Displayed]"
          end
        end
        for _, text in ipairs(vim.split(display_content or "", "\n", { plain = true, trimempty = trimempty })) do
          table.insert(lines, text)
        end

        last_set_role = msg.role
        last_role = msg.role

        -- The Chat:Submit method will parse the last message and it to the messages table
        if i == #msgs then
          table.remove(msgs, i)
        end
      end
    end
  end

  if chat_data.settings then
    lines = { "---" }
    table.insert(lines, string.format("adapter: %s", vim.inspect(chat_data.adapter)))
    table.insert(lines, string.format("model: %s", vim.inspect(chat_data.settings.model)))
    -- Sort keys alphabetically
    local sorted_keys = {}
    for key in pairs(chat_data.settings) do
      table.insert(sorted_keys, key)
    end
    table.sort(sorted_keys)
    for _, key in ipairs(sorted_keys) do
      if key ~= "model" then
        table.insert(lines, string.format("%s: %s", key, vim.inspect(chat_data.settings[key])))
      end
    end
    table.insert(lines, "---")
    spacer()
  end
  -- Handle both old (refs) and new (context_items) storage formats for preview
  local stored_context_items = chat_data.context_items or chat_data.refs or {}
  render_context_items(stored_context_items)
  if vim.tbl_isempty(chat_data.messages) then
    set_header(lines, user_role)
    spacer()
  else
    add_messages_to_buf(chat_data.messages)
  end
  return lines
end

local function select_opts(prompt, conditional)
  return {
    prompt = prompt,
    kind = "codecompanion.nvim",
    format_item = function(item)
      if conditional == item then
        return "* " .. item
      end
      return "  " .. item
    end,
  }
end

return UI
