local require = require("noice.util.lazy")

local Config = require("noice.config")
local ConfigViews = require("noice.config.views")
local Format = require("noice.text.format")
local Message = require("noice.message")
local Object = require("nui.object")
local Util = require("noice.util")

---@class NoiceViewBaseOptions
---@field buf_options? table<string,any>
---@field backend string|string[]
---@field fallback string Fallback view in case the backend could not be loaded
---@field format? NoiceFormat|string
---@field align? NoiceAlign
---@field lang? string
---@field view string

---@alias NoiceViewOptions NoiceViewBaseOptions|NoiceNuiOptions|NoiceNotifyOptions

---@class NoiceView
---@field _tick number
---@field _messages NoiceMessage[]
---@field _id integer
---@field _opts NoiceViewOptions
---@field _view_opts NoiceViewOptions
---@field _route_opts NoiceViewOptions
---@field _visible boolean
---@field _instance "opts" | "view" | "backend"
---@field _errors integer
---@overload fun(opts?: NoiceViewOptions): NoiceView
local View = Object("NoiceView")

---@type {view:NoiceView, opts:NoiceViewOptions}[]
View._views = {}

---@param view string
---@param opts NoiceViewOptions
function View.get_view(view, opts)
  local opts_orig = vim.deepcopy(opts)
  opts = vim.tbl_deep_extend("force", ConfigViews.get_options(view), opts or {}, { view = view })

  ---@diagnostic disable-next-line: undefined-field
  opts.backend = opts.backend or opts.render or view

  ---@type string[]
  local backends = type(opts.backend) == "table" and opts.backend or { opts.backend }

  for _, backend in ipairs(backends) do
    opts.backend = backend
    -- check if we already loaded this backend
    for _, v in ipairs(View._views) do
      if v.opts.view == opts.view then
        if v.view._instance == "opts" and vim.deep_equal(opts, v.opts) then
          return v.view
        end
        if v.view._instance == "view" then
          return v.view
        end
      end
      if v.opts.backend == backend then
        if v.view._instance == "backend" then
          return v.view
        end
      end
    end

    ---@type NoiceView
    local mod = require("noice.view.backend." .. backend)
    local init_opts = vim.deepcopy(opts)
    local ret = mod(opts)
    if ret:is_available() then
      table.insert(View._views, { view = ret, opts = init_opts })
      return ret
    end
  end

  return opts.fallback and View.get_view(opts.fallback, opts_orig) or nil
end

local _id = 0
---@param opts? NoiceViewOptions
function View:init(opts)
  _id = _id + 1
  self._id = _id
  self._tick = 0
  self._messages = {}
  self._opts = opts or {}
  self._visible = false
  self._view_opts = vim.deepcopy(self._opts)
  self._instance = "opts"
  self._errors = 0
  self:update_options()
end

function View:is_available()
  return true
end

function View:update_options() end

---@param messages NoiceMessage|NoiceMessage[]
---@param opts? {format?: boolean}
function View:push(messages, opts)
  opts = opts or {}

  messages = vim.islist(messages) and messages or { messages }
  ---@cast messages NoiceMessage[]

  for _, message in ipairs(messages) do
    if opts.format ~= false then
      message = Format.format(message, self._opts.format)
    end
    table.insert(self._messages, message)
  end
end

function View:clear()
  self._messages = {}
  self._route_opts = {}
end

function View:dismiss()
  self:clear()
end

function View:check_options()
  ---@type NoiceViewOptions
  local old = vim.deepcopy(self._opts)
  self._opts = vim.tbl_deep_extend("force", vim.deepcopy(self._view_opts), self._route_opts or {})
  self:update_options()
  if not vim.deep_equal(old, self._opts) then
    self:reset(old, self._opts)
  end
end

---@param messages NoiceMessage[]
---@param opts? {format?: boolean}
function View:set(messages, opts)
  opts = opts or {}
  self:clear()
  self:push(messages, opts)
end

function View:debug(msg)
  if Config.options.debug then
    Util.debug(("[%s] %s"):format(self._opts.view, vim.inspect(msg)))
    Util.debug(debug.traceback())
  end
end

-- Safely destroys any create windows and buffers.
-- This is needed to properly re-create views in case of E565 errors
function View:destroy() end

function View:display()
  if #self._messages > 0 then
    Format.align(self._messages, self._opts.align)
    self:check_options()

    Util.protect(function()
      self._errors = self._errors + 1
      self:show()
      self._errors = 0
    end, {
      catch = function(err)
        self:debug(err)
        self:destroy()
      end,
    })()

    self._visible = true
  else
    if self._visible then
      self:hide()
    end
    self._visible = false
  end
  return true
end

---@param old NoiceViewOptions
---@param new NoiceViewOptions
function View:reset(old, new) end

function View:show()
  Util.error("Missing implementation `View:show()` for %s", self)
end

function View:hide()
  Util.error("Missing implementation `View:hide()` for %s", self)
end

---@param messages? NoiceMessage[]
function View:height(messages)
  local ret = 0
  for _, m in ipairs(messages or self._messages) do
    ret = ret + m:height()
  end
  return ret
end

---@param messages? NoiceMessage[]
function View:width(messages)
  local ret = 0
  for _, m in ipairs(messages or self._messages) do
    ret = math.max(ret, m:width())
  end
  return ret
end

function View:content()
  return table.concat(
    vim.tbl_map(
    ---@param m NoiceMessage
      function(m)
        return m:content()
      end,
      self._messages
    ),
    "\n"
  )
end

function View:set_win_options(win)
  if self._opts.win_options then
    Util.wo(win, self._opts.win_options)
  end
  -- reset cursor on show
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  if self._opts.type == "split" then
    vim.schedule(function()
      -- this is needed to make the nui split behave with vim.go.splitkeep
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        vim.api.nvim_win_call(win, function()
          vim.cmd([[noautocmd silent! normal! zt]])
        end)
      end
    end)
  end
end

---@param buf number buffer number
---@param opts? {offset: number, highlight: boolean, messages?: NoiceMessage[]} line number (1-indexed), if `highlight`, then only highlight
function View:render(buf, opts)
  if not Config.is_running() then
    return
  end
  opts = opts or {}
  local linenr = opts.offset or 1

  if self._opts.buf_options then
    Util.ignore_events(function()
      require("nui.utils")._.set_buf_options(buf, self._opts.buf_options)
    end)
  end

  if self._opts.lang and not vim.b[buf].ts_highlight then
    if not pcall(vim.treesitter.start, buf, self._opts.lang) then
      vim.bo[buf].syntax = self._opts.lang
    end
  end

  vim.api.nvim_buf_clear_namespace(buf, Config.ns, linenr - 1, -1)
  Message._buf_messages[buf] = {}

  if not opts.highlight then
    vim.api.nvim_buf_set_lines(buf, linenr - 1, -1, false, {})
  end

  for _, m in ipairs(opts.messages or self._messages) do
    if opts.highlight then
      m:highlight(buf, Config.ns, linenr)
    else
      m:render(buf, Config.ns, linenr)
    end
    linenr = linenr + m:height()
  end
end

return View
