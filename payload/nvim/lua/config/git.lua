-- Git integration: Zed-style git panel (Telescope), unified diffs, hunk actions.
local api = vim.api
local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO)
end

local function git_root()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 or #out == 0 then
    return nil
  end
  return out[1]
end

local function relative_file()
  local root = git_root()
  local name = api.nvim_buf_get_name(0)
  if not root or name == "" then
    return nil
  end
  return vim.fs.relpath(root, name)
end

local function run(args, opts)
  opts = opts or {}
  local out = vim.fn.systemlist(args)
  if vim.v.shell_error ~= 0 then
    notify(table.concat(out, "\n"), opts.level or vim.log.levels.ERROR)
    return false
  end
  if opts.notify ~= false then
    notify(opts.message or ("OK: " .. table.concat(args, " ")))
  end
  return true
end

function M.diff()
  if not git_root() then
    notify("Not a git repository", vim.log.levels.WARN)
    return
  end
  local rel = relative_file()
  if rel then
    vim.cmd("Git diff -- " .. vim.fn.fnameescape(rel))
  else
    vim.cmd("Git diff")
  end
end

function M.diff_staged()
  if not git_root() then
    return
  end
  local rel = relative_file()
  if rel then
    vim.cmd("Git diff --cached -- " .. vim.fn.fnameescape(rel))
  else
    vim.cmd("Git diff --cached")
  end
end

function M.review()
  vim.cmd("DiffviewOpen")
end

function M.file_history()
  local name = api.nvim_buf_get_name(0)
  if name ~= "" and vim.fn.filereadable(name) == 1 then
    vim.cmd("DiffviewFileHistory %")
  else
    vim.cmd("DiffviewFileHistory")
  end
end

function M.close_diff()
  if vim.fn.exists(":DiffviewClose") == 2 then
    vim.cmd("DiffviewClose")
  else
    vim.cmd("diffoff!")
    vim.cmd("close")
  end
end

function M.status()
  if not git_root() then
    notify("Not a git repository", vim.log.levels.WARN)
    return
  end
  require("telescope.builtin").git_status({
    prompt_title = "Git Changes",
  })
end

function M.commit()
  if not git_root() then
    return
  end
  local msg = vim.fn.input("Commit message: ")
  if msg == nil or vim.trim(msg) == "" then
    notify("Commit cancelled")
    return
  end
  if run({ "git", "commit", "-m", msg }, { message = "Committed" }) then
    vim.cmd("startinsert")
  end
end

function M.amend()
  if not git_root() then
    return
  end
  local msg = vim.fn.input("Amend commit message: ")
  if msg == nil or vim.trim(msg) == "" then
    notify("Amend cancelled")
    return
  end
  run({ "git", "commit", "--amend", "-m", msg }, { message = "Amended" })
end

function M.commit_message()
  -- Generate a commit message with OpenCode and put it in the command line.
  if not git_root() then
    return
  end
  local opencode = require("config.terminal").opencode_bin()
  if not opencode then
    notify("OpenCode is not installed", vim.log.levels.WARN)
    return
  end
  local diff = vim.fn.systemlist({ "git", "diff", "--cached", "--stat" })
  if vim.v.shell_error ~= 0 or #diff == 0 then
    notify("Nothing staged", vim.log.levels.WARN)
    return
  end
  notify("Generating commit message with OpenCode…")
  local prompt = "Write a concise Conventional Commit message for the staged changes. Return only the subject line, no quotes, no explanation."
  vim.fn.jobstart({ opencode, "run", prompt }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      local text = table.concat(data, "\n")
      text = vim.trim(text)
      if text ~= "" then
        vim.schedule(function()
          vim.fn.setreg("+", text)
          vim.notify("Commit message copied to clipboard:\n" .. text)
        end)
      end
    end,
  })
end

function M.stage_all()
  if run({ "git", "add", "-A" }, { message = "Staged all changes" }) then
    pcall(function()
      require("gitsigns").refresh()
    end)
  end
end

function M.unstage_all()
  if run({ "git", "reset" }, { message = "Unstaged all changes" }) then
    pcall(function()
      require("gitsigns").refresh()
    end)
  end
end

function M.push()
  run({ "git", "push" }, { message = "Pushed" })
end

function M.pull()
  run({ "git", "pull" }, { message = "Pulled" })
end

function M.blame()
  local ok, gitsigns = pcall(require, "gitsigns")
  if ok then
    gitsigns.blame_line({ full = true })
  end
end

function M.next_hunk()
  local ok, gitsigns = pcall(require, "gitsigns")
  if ok then
    gitsigns.nav_hunk("next")
  end
end

function M.prev_hunk()
  local ok, gitsigns = pcall(require, "gitsigns")
  if ok then
    gitsigns.nav_hunk("prev")
  end
end

function M.stage_hunk()
  local ok, gitsigns = pcall(require, "gitsigns")
  if not ok then
    return
  end
  gitsigns.stage_hunk()
  gitsigns.nav_hunk("next")
end

function M.unstage_hunk()
  local ok, gitsigns = pcall(require, "gitsigns")
  if not ok then
    return
  end
  gitsigns.unstage_hunk()
  gitsigns.nav_hunk("next")
end

function M.reset_hunk()
  local ok, gitsigns = pcall(require, "gitsigns")
  if not ok then
    return
  end
  gitsigns.reset_hunk()
end

function M.preview_hunk()
  local ok, gitsigns = pcall(require, "gitsigns")
  if ok then
    gitsigns.preview_hunk()
  end
end

-- User commands, handy from the command line / palette.
vim.api.nvim_create_user_command("GitStatus", function()
  M.status()
end, { desc = "Git: changed files" })
vim.api.nvim_create_user_command("GitDiff", function()
  M.diff()
end, { desc = "Git: unified diff for the current file" })
vim.api.nvim_create_user_command("GitDiffStaged", function()
  M.diff_staged()
end, { desc = "Git: staged unified diff" })
vim.api.nvim_create_user_command("GitReview", function()
  M.review()
end, { desc = "Git: side-by-side review" })
vim.api.nvim_create_user_command("GitHistory", function()
  M.file_history()
end, { desc = "Git: file history" })
vim.api.nvim_create_user_command("GitCommit", function()
  M.commit()
end, { desc = "Git: commit staged changes" })
vim.api.nvim_create_user_command("GitAmend", function()
  M.amend()
end, { desc = "Git: amend commit" })
vim.api.nvim_create_user_command("GitStageAll", function()
  M.stage_all()
end, { desc = "Git: stage all" })
vim.api.nvim_create_user_command("GitUnstageAll", function()
  M.unstage_all()
end, { desc = "Git: unstage all" })
vim.api.nvim_create_user_command("GitPush", function()
  M.push()
end, { desc = "Git: push" })
vim.api.nvim_create_user_command("GitPull", function()
  M.pull()
end, { desc = "Git: pull" })

return M
