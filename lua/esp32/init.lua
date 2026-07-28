local M = {}

---@class ESP32Opts
local defaults = {
  build_dir = "build.clang",
  baudrate = 115200,
  clangd_args = {},
  idf_cmd = nil,
}

M.options = vim.deepcopy(defaults)
M.state = {
  last_port = nil,
}

local function get_snacks()
  return require("snacks")
end

local function make_clangd_capabilities()
  local capabilities = vim.lsp.protocol.make_client_capabilities()

  -- clangd moved from the custom offsetEncoding extension to the standard
  -- positionEncodings capability in LSP 3.17.
  if capabilities.general then
    capabilities.general.positionEncodings = { "utf-16" }
  else
    capabilities.offsetEncoding = { "utf-16" }
  end

  return capabilities
end

local function is_windows()
  return vim.fn.has("win32") == 1
end

local function get_home()
  return vim.env.HOME or vim.fn.expand("~")
end

local function join_path(...)
  return table.concat({ ... }, "/")
end

local function shellescape(value)
  return vim.fn.shellescape(tostring(value))
end

local function executable_path(path)
  return path and vim.fn.executable(path) == 1
end

--- Candidate ESP-IDF tools directories, most specific first
local function idf_tools_dirs()
  local dirs = {}
  local seen = {}

  local function add(dir)
    if dir and dir ~= "" and not seen[dir] then
      seen[dir] = true
      table.insert(dirs, dir)
    end
  end

  if vim.env.IDF_TOOLS_PATH and vim.env.IDF_TOOLS_PATH ~= "" then
    -- EIM points IDF_TOOLS_PATH at the tools dir itself, classic
    -- idf_tools.py points it at the .espressif root with tools/ inside.
    add(vim.env.IDF_TOOLS_PATH)
    add(join_path(vim.env.IDF_TOOLS_PATH, "tools"))
  end

  add(join_path(get_home(), ".espressif", "tools"))

  if is_windows() then
    -- EIM's default install location on Windows
    add("C:/Espressif/tools")
  end

  return dirs
end

--- Find the Python interpreter of an ESP-IDF virtualenv
local function find_venv_python(env_path)
  local candidates
  if is_windows() then
    candidates = {
      join_path(env_path, "Scripts", "python.exe"),
      join_path(env_path, "python.exe"),
    }
  else
    candidates = { join_path(env_path, "bin", "python") }
  end

  for _, python in ipairs(candidates) do
    if executable_path(python) then
      return python
    end
  end
end

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.options or {}, opts or {})
  M.ensure_clangd()
end

--- List available cu.* serial ports
function M.list_ports()
  local scandir = vim.uv.fs_scandir("/dev")
  local ports = {}
  local patterns = {
    "^cu%.",
    "^ttyUSB%d+$",
    "^ttyACM%d+$",
    "^tty%.usb",
    "^tty%.wchusbserial",
  }

  if scandir then
    while true do
      local name = vim.uv.fs_scandir_next(scandir)
      if not name then
        break
      end

      for _, pattern in ipairs(patterns) do
        if name:match(pattern) then
          table.insert(ports, { port = "/dev/" .. name })
          break
        end
      end
    end
  end

  table.sort(ports, function(a, b)
    return a.port < b.port
  end)

  return ports
end

--- Find the ESP-IDF specific clangd
function M.find_esp_clangd()
  -- if clangd is on the path, check if it is from espressif using.
  -- if so, we are done
  if vim.fn.executable("clangd") == 1 then
    -- use `clangd --version` to check if it is from espressif
    local clangd_version = vim.fn.system("clangd --version")
    if clangd_version:match("espressif") then
      -- return the absolute path to clangd
      return vim.fn.exepath("clangd")
    end
  end

  for _, tools_dir in ipairs(idf_tools_dirs()) do
    local base = join_path(tools_dir, "esp-clang")
    local scandir = vim.uv.fs_scandir(base)
    if scandir then
      local latest
      local latest_key
      while true do
        local name = vim.uv.fs_scandir_next(scandir)
        if not name then
          break
        end
        if name:match("^esp%-.+") then
          local candidate = join_path(base, name, "esp-clang", "bin", "clangd")
          if vim.fn.executable(candidate) == 1 and (not latest_key or name > latest_key) then
            latest = candidate
            latest_key = name
          end
        end
      end
      if latest then
        return latest
      end
    end
  end

  return nil
end

--- Resolve a command prefix that can run idf.py
function M.resolve_idf_cmd()
  if type(M.options.idf_cmd) == "string" and M.options.idf_cmd ~= "" then
    return M.options.idf_cmd
  end

  if executable_path("idf.py") then
    return "idf.py"
  end

  if vim.env.IDF_PATH then
    local idf_py = join_path(vim.env.IDF_PATH, "tools", "idf.py")
    if vim.fn.filereadable(idf_py) == 1 then
      if vim.env.IDF_PYTHON_ENV_PATH then
        local venv_python = find_venv_python(vim.env.IDF_PYTHON_ENV_PATH)
        if venv_python then
          return shellescape(venv_python) .. " " .. shellescape(idf_py)
        end
      end
    end
  end

  return "idf.py"
end

--- Create an idf.py command line
function M.make_idf_command(cmd, port)
  local full_cmd = M.resolve_idf_cmd() .. " -B " .. shellescape(M.options.build_dir)
  local selected_port = port or M.state.last_port

  if selected_port then
    full_cmd = full_cmd .. " -p " .. shellescape(selected_port)
  end

  return full_cmd .. " " .. cmd
end

--- Locate the compile database, resolving build_dir against a project root
---
--- build_dir is relative by default, and Neovim's working directory is not
--- necessarily the project, so prefer the root clangd itself resolved against.
local function compile_commands_path(root)
  local dir = M.options.build_dir
  local is_absolute = dir:match("^[/\\]") or dir:match("^%a:[/\\]")

  if root and not is_absolute then
    dir = join_path(root, dir)
  end

  return join_path(dir, "compile_commands.json")
end

--- Identify the compiler a compile database was generated for
---
--- Returns "clang", "gcc", or nil when the database is missing or the compiler
--- cannot be recognised. A database written for the GCC toolchain drives clangd
--- into reporting unknown arguments and missing headers, because the ESP-IDF
--- GCC flags and newlib headers have no clang equivalent.
function M.compile_commands_toolchain(root)
  local path = compile_commands_path(root)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end

  -- The database grows with the project, so read only far enough to reach the
  -- compiler of the first entry rather than loading the whole file.
  local head = table.concat(vim.fn.readfile(path, "", 40), "\n")
  local compiler = head:match('"command"%s*:%s*"([^"%s]+)')
    or head:match('"arguments"%s*:%s*%[%s*"([^"]+)"')

  if not compiler then
    return nil
  end

  if compiler:match("%-gcc") then
    return "gcc"
  end

  if compiler:match("clang") then
    return "clang"
  end

  return nil
end

--- Ensure compile_commands.json exists and was generated for clang
function M.ensure_compile_commands(root)
  local path = compile_commands_path(root)
  if vim.fn.filereadable(path) == 0 then
    vim.notify("[ESP32] ⚠️ Missing compile_commands.json in " .. path, vim.log.levels.WARN)
    return
  end

  if M.compile_commands_toolchain(root) == "gcc" then
    vim.notify(
      "[ESP32] ⚠️ " .. path .. " was generated for the GCC toolchain."
        .. "\nclangd will report unknown arguments and missing headers."
        .. "\nRun :ESPReconfigure to regenerate it with IDF_TOOLCHAIN=clang.",
      vim.log.levels.WARN
    )
  end
end

--- Projects already reported on, so one bad build dir warns once per session
local checked_roots = {}

--- Check the compile database of a project clangd just attached to
---
--- Hooked to LspAttach rather than to opening a buffer because that is where
--- the resolved project root is available, and because the warnings only
--- describe how clangd behaves.
function M.check_attached_client(client_id)
  local client = vim.lsp.get_client_by_id(client_id)
  if not client or client.name ~= "clangd" then
    return
  end

  local root = client.root_dir
  if not root or checked_roots[root] then
    return
  end

  checked_roots[root] = true
  M.ensure_compile_commands(root)
end

vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("Esp32CheckCompileCommands", { clear = true }),
  callback = function(args)
    M.check_attached_client(args.data and args.data.client_id)
  end,
})

--- Ensure esp-clangd exists and warn if not
function M.ensure_clangd()
  if not M.find_esp_clangd() then
    vim.notify("[ESP32] ⚠️ ESP-specific clangd not found. LSP may not work properly.", vim.log.levels.WARN)
  end
end

--- Open a Snacks terminal for idf.py command
function M.command(cmd, port)
  local Snacks = get_snacks()
  local full_cmd = M.make_idf_command(cmd, port)

  local terminal_opts = {
    win = {
      width = 0.6,
      height = 0.7,
      border = "single",
      title = "Ctrl + ] to stop",
      title_pos = "center",
    },
  }

  if cmd == "monitor" then
    Snacks.terminal.toggle(full_cmd, terminal_opts)
  else
    Snacks.terminal.open(full_cmd, terminal_opts)
  end
end

--- Run idf.py build
function M.build()
  M.command("build")
end

-- Setup build command for Neovim
vim.api.nvim_create_user_command("ESPBuild", function()
  M.build()
end, {})

--- Create Snacks picker for port and run idf.py command
function M.pick(cmd)
  local Snacks = get_snacks()
  Snacks.picker.pick({
    prompt = "Select ESP32 port",
    ui_select = true,
    focus = "list",
    finder = M.list_ports,
    layout = {
      layout = {
        box = "horizontal",
        width = 0.2,
        height = 0.2,
        {
          box = "vertical",
          border = "single",
          title = "USB Serial Ports",
          { win = "input", height = 1,     border = "bottom" },
          { win = "list",  border = "none" },
        },
      },
    },
    format = function(item)
      local a = Snacks.picker.util.align
      return { { a(item.port, 20, { align = "left" }) } }
    end,
    confirm = function(picker, item)
      picker:close()
      M.state.last_port = item.port
      M.command(cmd, item.port)
    end,
  })
end

--- Run idf.py reconfigure for build.clang
function M.reconfigure()
  local Snacks = get_snacks()
  -- The build dir is about to change, so let it be reported on again.
  checked_roots = {}
  Snacks.terminal.open(M.make_idf_command("-D IDF_TOOLCHAIN=clang reconfigure"), {
    win = {
      width = 0.5,
      height = 0.4,
      title = "ESP-IDF Reconfigure",
      title_pos = "center",
    },
  })
end

--- Set up ESP32 LSP configuration
function M.lsp_config()
  local clangd = M.find_esp_clangd()
  if not clangd then
    vim.notify("[ESP32] No esp-clangd found. Falling back to system clangd.", vim.log.levels.WARN)
    clangd = "clangd"
  end
  local cmd = {
    clangd,
    "--compile-commands-dir=" .. M.options.build_dir,
    "--background-index",
    "--clang-tidy",
    "--header-insertion=iwyu",
    "--completion-style=detailed",
    -- clangd 20 rejects the bare flag and wants an explicit boolean.
    "--function-arg-placeholders=true",
    "--fallback-style=llvm",
  }

  vim.list_extend(cmd, M.options.clangd_args or {})

  return {
    cmd = cmd,
    -- Prefer the ESP-IDF project root and avoid falling back to a parent git
    -- repository, which breaks nested projects/monorepos.
    root_markers = { "sdkconfig", "CMakeLists.txt" },
    capabilities = make_clangd_capabilities(),
    init_options = {
      usePlaceholders = true,
      completeUnimported = true,
      clangdFileStatus = true,
    },
  }
end

--- Show ESP32 setup info
function M.info()
  local messages = {}

  -- clangd check
  if M.find_esp_clangd() then
    table.insert(messages, "✓ Found esp-clangd")
  else
    table.insert(messages, "✗ ESP-specific clangd missing")
  end

  -- compile_commands.json check
  local build_dir = M.options.build_dir
  local path = build_dir .. "/compile_commands.json"
  if vim.fn.filereadable(path) == 1 then
    local toolchain = M.compile_commands_toolchain()
    if toolchain == "gcc" then
      table.insert(messages, "✗ compile_commands.json was generated for GCC, run :ESPReconfigure")
    else
      table.insert(messages, "✓ compile_commands.json exists")
    end
  else
    table.insert(messages, "✗ compile_commands.json missing")
  end

  -- Check ESP-IDF environment
  local function check_bin(bin)
    return vim.fn.executable(bin) == 1 and "✓" or "✗"
  end

  local has_idf_cmd = M.resolve_idf_cmd() ~= "idf.py" or check_bin("idf.py") == "✓"
  table.insert(messages, (has_idf_cmd and "✓" or "✗") .. " idf.py")
  table.insert(messages, check_bin("llvm-ar") .. " llvm-ar")
  table.insert(messages, "IDF_PATH: " .. (vim.env.IDF_PATH or "✗ not set"))

  if vim.env.IDF_PATH == nil then
    table.insert(messages, "⚠️ Source an ESP-IDF environment before launching Neovim:")
    if is_windows() then
      table.insert(messages, [[. C:\Espressif\tools\Microsoft.<version>.PowerShell_profile.ps1]])
    else
      table.insert(messages, "source ~/.espressif/tools/activate_idf_<version>.sh")
      table.insert(messages, "or source ~/esp/esp-idf/export.sh")
    end
  end

  vim.notify(table.concat(messages, "\n"), vim.log.levels.INFO)
end

-- Setup custom commands for Neovim
vim.api.nvim_create_user_command("ESPReconfigure", function()
  M.reconfigure()
end, {})

vim.api.nvim_create_user_command("ESPInfo", function()
  M.info()
end, {})

return M
