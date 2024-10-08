local M = {}

local user_opts = {
  border = nil,
  max_col_num = 5,
  min_col_width = 20,
  use_matchfuzzy = true,
  highlight_selection = true,
  highlight_directories = true,
  tab_completion = true,
  filter_completion = function(input)
    -- NOTE: shell autcomplete is very slow
    if vim.startswith(input, '!') or vim.startswith(input, '\'') then
      return false
    end
    return true
  end,
}

-- there isn't an API for builtin command descriptions
-- these are taken from :help
local builtin_command_desc = {
  quit = "Quit the current window",
  q = "Quit the current window",
  write = "Write the whole buffer to the current file",
  w = "Write the whole buffer to the current file",
  ["write!"] =
  "Like \":write\", but forcefully write when 'readonly' is set or there is another reason why writing was refused",
  ["w!"] =
  "Like \":write\", but forcefully write when 'readonly' is set or there is another reason why writing was refused",
  wq = "Write the current file and close the window",
  ["wq!"] = "Write the current file and close the window",
  wa = "Write all changed buffers",
  wall = "Write all changed buffers",
  ["wa!"] = "Write all changed buffers, even the ones that are readonly",
  ["wall!"] = "Write all changed buffers, even the ones that are readonly",
  wqa = "Write all changed buffers and exit Vim",
  wqall = "Write all changed buffers and exit Vim",
  qa = "Exit Vim, unless there are some buffers which have been changed",
  qall = "Exit Vim, unless there are some buffers which have been changed",
  quitall = "Exit Vim, unless there are some buffers which have been changed",
  quita = "Exit Vim, unless there are some buffers which have been changed",
  n = "Create a new window and start editing an empty file in it",
  new = "Create a new window and start editing an empty file in it",
  h = "Open a window and display the help file in read-only mode",
  help = "Open a window and display the help file in read-only mode",
}

local current_completions = {}
local current_selection = 1
local cmdline_changed_disabled = false
local in_that_cursed_cmdwin = false
local search_hl_nsid = vim.api.nvim_create_namespace('__ccs_hls_namespace_search___')
local directory_hl_nsid = vim.api.nvim_create_namespace('__ccs_hls_namespace_directory___')

local function calc_col_width()
  local col_width
  local cols = 0
  for i = 1, user_opts.max_col_num do
    local test_width = math.floor(vim.o.columns / i)
    cols = cols + 1
    if test_width <= user_opts.min_col_width then
      return col_width, cols
    else
      col_width = test_width
    end
  end

  return col_width, cols
end

local function open_and_setup_win(height)
  if not M.wbufnr then
    M.wbufnr = vim.api.nvim_create_buf(false, true)
  end

  M.winid = vim.api.nvim_open_win(M.wbufnr, false, {
    relative = 'editor',
    border = user_opts.border,
    style = 'minimal',
    width = vim.o.columns,
    height = height,
    row = vim.o.lines - 4,
    col = 0,
  })

  vim.cmd('redraw')
end

---@param desc string|nil
local function set_desc_win(desc)
  if desc == nil or #desc == 0 then
    if M.desc_winid then
      vim.api.nvim_win_close(M.desc_winid, true)
      M.desc_winid = nil
    end
    return
  end

  if not M.winid then
    return
  end

  assert(type(desc) == "string")

  if not M.desc_wbufnr then
    M.desc_wbufnr = vim.api.nvim_create_buf(false, true)
  end

  local completion_win_config = vim.api.nvim_win_get_config(M.winid)
  local desc_win_height = 1
  local desc_win_config = {
    relative = 'win',
    win = M.winid,
    style = 'minimal',
    border = 'rounded',
    width = #desc,
    height = desc_win_height,
    row = -desc_win_height - completion_win_config.height,
    col = 0,
  }

  -- NOTE: I have no idea why this works
  if completion_win_config.height == 1 then
    desc_win_config.row = desc_win_config.row - 1;
  end

  if not M.desc_winid then
    M.desc_winid = vim.api.nvim_open_win(M.desc_wbufnr, false, desc_win_config)
  else
    vim.api.nvim_win_set_config(M.desc_winid, desc_win_config)
  end

  -- clear
  vim.api.nvim_buf_set_lines(M.desc_wbufnr, 0, -1, true, {})
  vim.api.nvim_buf_set_lines(M.desc_wbufnr, 0, -1, false, vim.split(desc, '\n'))
end

local function split_cmdline(cmdline)
  return vim.split(cmdline, '[ .=]')
end

local function update_cmdline_desc(cmdline)
  local input_split = split_cmdline(cmdline)
  local command_desc = nil
  local commands = vim.api.nvim_get_commands({})
  local command_name = vim.trim(input_split[1])
  if vim.fn.has_key(commands, command_name) then
    local command = commands[command_name]
    if command ~= nil and vim.fn.has_key(command, "definition") then
      command_desc = command["definition"]
    end
  end

  if not command_desc then
    if vim.fn.has_key(builtin_command_desc, command_name) then
      command_desc = builtin_command_desc[command_name]
    end
  end

  set_desc_win(command_desc)
end

local function setup_handlers()
  if in_that_cursed_cmdwin then
    return
  end

  local height = math.floor(vim.o.lines * 0.3)
  local col_width, cols = calc_col_width()
  open_and_setup_win(height)

  local tbl = {}
  for _ = 0, height do
    tbl[#tbl + 1] = (' '):rep(vim.o.columns)
  end
  vim.api.nvim_buf_set_lines(M.wbufnr, 0, height, false, tbl)

  local function autocmd_cb()
    local input = vim.fn.getcmdline()

    if not user_opts.filter_completion(input) then
      if not cmdline_changed_disabled and M.winid then
        vim.api.nvim_win_close(M.winid, true)
        M.winid = nil
      end
      return
    end

    if cmdline_changed_disabled then
      update_cmdline_desc(input)
      return
    end

    if not M.winid then
      open_and_setup_win(height)
    end

    local completions = vim.fn.getcompletion(input, 'cmdline')

    -- Clear window
    vim.api.nvim_buf_set_lines(M.wbufnr, 0, height, false, tbl)

    -- TODO(smolck): No clue if this really helps much if at all but we'll use it
    -- by default for now
    -- if user_opts.use_matchfuzzy and input ~= '' then
    --   local str_to_match = input_split[#input_split]
    --
    --   completions = vim.fn.matchfuzzy(completions, str_to_match)
    -- end

    -- TODO(smolck): This *should* only apply to suggestions that are files, but
    -- I'm not totally sure if that's right so might need to be properly tested.
    -- (Or maybe find a better way of cutting down filepath suggestions to their tails?)
    completions = vim.tbl_map(function(c)
      local is_directory = vim.fn.isdirectory(vim.fn.fnamemodify(c, ':p')) == 1
      local f1 = vim.fn.fnamemodify(c, ':p:t')

      local ret
      if f1 == '' then
        -- This is for filepaths like '/Users/someuser/thing/', where if you get
        -- the tail it's just empty.
        ret = vim.fn.fnamemodify(c, ':p:h:t')
      else
        ret = f1
      end

      if string.len(ret) >= col_width then
        ret = string.sub(ret, 1, col_width - 5) .. '...'
      end

      return { completion = ret, is_directory = is_directory, full_completion = c }
    end, completions)

    current_completions = {}
    current_selection = -1

    -- Don't show completion window if there are no completions.
    if vim.tbl_isempty(completions) then
      vim.api.nvim_win_close(M.winid, true)
      M.winid = nil

      if M.desc_winid then
        vim.api.nvim_win_close(M.desc_winid, true)
        M.desc_winid = nil
      end
      return
    end

    local new_height = math.min(height, math.ceil(#completions / (cols + 1)))
    vim.api.nvim_win_set_config(M.winid, {
      relative = 'editor',
      border = user_opts.border,
      style = 'minimal',
      width = vim.o.columns,
      height = new_height,
      row = vim.o.lines - new_height - 1,
      col = 0,
    })

    local col = -1
    for i, item in ipairs(completions) do
      local line = (i - 1) % new_height
      if line == 0 then
        col = col + 1
      end
      local end_col = col * col_width + string.len(item.completion)
      if end_col > vim.o.columns then
        break
      end

      vim.api.nvim_buf_set_text(
        M.wbufnr, line, col * col_width, line, end_col,
        { item.completion }
      )

      current_completions[i] = {
        start = { line, col * col_width },
        finish = { line, end_col },
        full_completion = completions[i].full_completion,
      }

      if i == current_selection and user_opts.highlight_selection then
        vim.highlight.range(M.wbufnr, search_hl_nsid, 'Search', { line, col * col_width }, { line, end_col }, {})
      end

      if completions[i].is_directory and user_opts.highlight_directories then
        vim.highlight.range(
          M.wbufnr,
          directory_hl_nsid,
          'Directory',
          { line, col * col_width },
          { line, end_col },
          {}
        )
      end
    end
    vim.api.nvim_win_set_height(M.winid, new_height)
    vim.cmd('redraw')
    update_cmdline_desc(input)
    vim.cmd('redraw')
  end

  M.cmdline_changed_autocmd = vim.api.nvim_create_autocmd({ 'CmdlineChanged' }, {
    callback = autocmd_cb,
  })

  -- Initial completions when cmdline is already open and empty
  autocmd_cb()
end

local function teardown_handlers()
  if M.cmdline_changed_autocmd then
    vim.api.nvim_del_autocmd(M.cmdline_changed_autocmd)
    M.cmdline_changed_autocmd = nil
  end
  if M.winid then                    -- TODO(smolck): Check if vim.api.nvim_win_is_valid(M.winid)?
    if in_that_cursed_cmdwin then
      vim.api.nvim_win_hide(M.winid) -- Idk but it works (EDIT: NOT REALLY this is probably quite bad, so prepare for breakge
      -- just gotta fix this upstream I guess by making cmdwin sane with float and stuff
      -- TODO(smolck): come back once you've hopefully done that upstream)
    else
      vim.api.nvim_win_close(M.winid, true)
    end
  end
  if M.desc_winid then
    vim.api.nvim_win_close(M.desc_winid, true)
  end
  M.winid = nil
  M.desc_winid = nil
  current_selection = 1

  if M.wbufnr then
    vim.api.nvim_buf_set_lines(M.wbufnr, 0, -1, true, {})
  end
  if M.desc_wbufnr then
    vim.api.nvim_buf_set_lines(M.desc_wbufnr, 0, -1, true, {})
  end
end

local previewing_colorscheme = false
local before_preview_colorscheme = ""

local function tab_completion(direction)
  if vim.tbl_isempty(current_completions) then
    current_selection = 1
    return
  end

  if current_selection == -1 then
    if direction > 0 then
      current_selection = 1
    else
      current_selection = #current_completions
    end
  else
    if direction > 0 then
      current_selection = current_selection + direction > #current_completions and 1 or current_selection + direction
    else
      current_selection = current_selection + direction < 1 and #current_completions or current_selection + direction
    end
  end

  vim.api.nvim_buf_clear_namespace(M.wbufnr, search_hl_nsid, 0, -1)
  vim.highlight.range(
    M.wbufnr,
    search_hl_nsid,
    'Search',
    current_completions[current_selection].start,
    current_completions[current_selection].finish,
    {}
  )

  -- TODO(smolck): Re-visit this when/if https://github.com/neovim/neovim/pull/18096 is merged.
  local cmdline = vim.fn.getcmdline()
  local cmdline_parts = split_cmdline(cmdline)
  local last_word_len = string.len(cmdline_parts[#cmdline_parts])
  local completion = current_completions[current_selection].full_completion

  cmdline_changed_disabled = true
  local new_cmdline = cmdline:sub(0, #cmdline - last_word_len) .. completion
  vim.fn.setcmdline(new_cmdline)
  update_cmdline_desc(new_cmdline)

  if vim.startswith(cmdline, "colorscheme ") then
    if not previewing_colorscheme then
      previewing_colorscheme = true
      before_preview_colorscheme = vim.g.colors_name
    end
    vim.cmd(new_cmdline)
  end

  vim.cmd('redraw')

  -- This is necessary, from @gpanders on matrix:
  --
  -- """
  -- what's probably happening is you are ignoring CmdlineChanged, running your function, and then removing it before the event loop has a chance to turn
  -- so you should instead ignore the event, run your callback, let the event loop turn, and then remove it
  -- which is what vim.schedule is for
  -- """
  --
  -- Just :%s/ignoring CmdlineChanged/setting cmdline_changed_disabled etc.
  vim.schedule(function()
    cmdline_changed_disabled = false
  end)
end

function M.setup(opts)
  opts = opts or {}
  for k, v in pairs(opts) do
    user_opts[k] = v
  end

  if user_opts.tab_completion then
    vim.keymap.set('c', '<Tab>', function()
      tab_completion(1)
    end)

    vim.keymap.set('c', '<S-Tab>', function()
      tab_completion(-1)
    end)
  end

  vim.api.nvim_create_autocmd({ 'CmdwinEnter' }, {
    callback = function()
      in_that_cursed_cmdwin = true

      -- Could also be entering cmdwin from cmdline so handle that
      if M.winid then
        teardown_handlers()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'CmdwinLeave' }, {
    callback = function()
      in_that_cursed_cmdwin = false
    end,
  })
  vim.api.nvim_create_autocmd({ 'CmdlineEnter' }, {
    callback = function()
      if vim.v.event.cmdtype == ':' then
        setup_handlers()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'CmdlineLeave' }, {
    callback = function()
      if vim.v.event.cmdtype == ':' then
        if vim.v.event.abort then
          vim.cmd("colorscheme " .. before_preview_colorscheme)
        end
        previewing_colorscheme = false
        before_preview_colorscheme = ""
        teardown_handlers()
      end
    end,
  })
end

return M
