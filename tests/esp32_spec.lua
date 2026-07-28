local MiniTest = require("mini.test")
local expect = MiniTest.expect

local T = MiniTest.new_set()

local original_notify = vim.notify
local original_home = vim.env.HOME
local original_idf_path = vim.env.IDF_PATH
local original_idf_python_env_path = vim.env.IDF_PYTHON_ENV_PATH
local original_idf_tools_path = vim.env.IDF_TOOLS_PATH
local original_fn = {}
local original_uv = {}
local notifications = {}

local function restore_command(name)
  pcall(vim.api.nvim_del_user_command, name)
end

local function reset_module()
  restore_command("ESPBuild")
  restore_command("ESPReconfigure")
  restore_command("ESPInfo")
  package.loaded["esp32"] = nil
  package.loaded["snacks"] = nil
end

local function load_module(snacks)
  package.loaded["snacks"] = snacks or {
    terminal = {
      open = function() end,
      toggle = function() end,
    },
    picker = {
      pick = function() end,
      util = {
        align = function(value)
          return value
        end,
      },
    },
  }

  return require("esp32")
end

local function set_scandir(entries_by_path)
  local iterators = {}

  vim.uv.fs_scandir = function(path)
    local entries = entries_by_path[path]
    if not entries then
      return nil
    end

    local handle = { path = path }
    iterators[handle] = vim.deepcopy(entries)
    return handle
  end

  vim.uv.fs_scandir_next = function(handle)
    local entries = iterators[handle]
    if not entries or #entries == 0 then
      return nil
    end

    return table.remove(entries, 1)
  end
end

local function reset_plugin_state(esp32)
  esp32.options = vim.deepcopy({
    build_dir = "build.clang",
    baudrate = 115200,
    clangd_args = {},
    idf_cmd = nil,
  })
  esp32.state = {
    last_port = nil,
  }
end

local function expect_truthy(value)
  expect.equality(not not value, true)
end

local function prepare_case()
  reset_module()
  notifications = {}
  vim.notify = function(message, level)
    table.insert(notifications, { message = message, level = level })
  end
  vim.env.HOME = original_home
  vim.env.IDF_PATH = nil
  vim.env.IDF_PYTHON_ENV_PATH = nil
  vim.env.IDF_TOOLS_PATH = nil
  vim.fn.has = original_fn.has
  vim.fn.executable = function()
    return 0
  end
  vim.fn.system = function()
    return ""
  end
  vim.fn.exepath = function(bin)
    return bin
  end
  vim.fn.filereadable = function()
    return 0
  end
  vim.fn.expand = function()
    return "/home/test"
  end
  vim.fn.readfile = function()
    return {}
  end
  set_scandir({})
end

--- Present a compile_commands.json whose first entry uses the given compiler
local function set_compile_commands(compiler)
  vim.fn.filereadable = function(path)
    return path:match("compile_commands%.json$") and 1 or 0
  end
  vim.fn.readfile = function()
    return {
      "[",
      "{",
      '  "directory": "/project/build.clang",',
      '  "command": "' .. compiler .. ' -DFOO -Iinclude -c main.c",',
      '  "file": "/project/main/main.c"',
      "}",
      "]",
    }
  end
end

T.hooks = {
  pre_once = function()
    original_fn.has = vim.fn.has
    original_fn.executable = vim.fn.executable
    original_fn.system = vim.fn.system
    original_fn.exepath = vim.fn.exepath
    original_fn.filereadable = vim.fn.filereadable
    original_fn.expand = vim.fn.expand
    original_fn.readfile = vim.fn.readfile
    original_uv.fs_scandir = vim.uv.fs_scandir
    original_uv.fs_scandir_next = vim.uv.fs_scandir_next
  end,
  post_once = function()
    reset_module()
    vim.notify = original_notify
    vim.env.HOME = original_home
    vim.env.IDF_PATH = original_idf_path
    vim.env.IDF_PYTHON_ENV_PATH = original_idf_python_env_path
    vim.env.IDF_TOOLS_PATH = original_idf_tools_path
    vim.fn.has = original_fn.has
    vim.fn.executable = original_fn.executable
    vim.fn.system = original_fn.system
    vim.fn.exepath = original_fn.exepath
    vim.fn.filereadable = original_fn.filereadable
    vim.fn.expand = original_fn.expand
    vim.fn.readfile = original_fn.readfile
    vim.uv.fs_scandir = original_uv.fs_scandir
    vim.uv.fs_scandir_next = original_uv.fs_scandir_next
  end,
}

T["list_ports() matches supported device names and sorts results"] = function()
  prepare_case()
  set_scandir({
    ["/dev"] = {
      "ttyUSB1",
      "not-a-port",
      "cu.usbmodem101",
      "ttyACM0",
      "tty.wchusbserial123",
      "tty.usbserial-0001",
      "ttyUSB0",
    },
  })

  local esp32 = load_module()
  reset_plugin_state(esp32)
  local ports = esp32.list_ports()

  expect.equality(ports, {
    { port = "/dev/cu.usbmodem101" },
    { port = "/dev/tty.usbserial-0001" },
    { port = "/dev/tty.wchusbserial123" },
    { port = "/dev/ttyACM0" },
    { port = "/dev/ttyUSB0" },
    { port = "/dev/ttyUSB1" },
  })
end

T["find_esp_clangd() picks the newest installed Espressif clangd"] = function()
  prepare_case()
  local previous_home = vim.env.HOME
  vim.env.HOME = "/home/test"
  vim.fn.expand = function()
    return "/home/test"
  end

  set_scandir({
    ["/home/test/.espressif/tools/esp-clang"] = {
      "esp-20.1.0_20240101",
      "esp-20.1.1_20250829",
      "esp-19.1.2_20231212",
    },
  })

  vim.fn.executable = function(path)
    if path == "clangd" then
      return 0
    end
    return 1
  end

  local esp32 = load_module()
  reset_plugin_state(esp32)
  local clangd = esp32.find_esp_clangd()

  expect_truthy(clangd)
  expect.equality(clangd:match("^/home/test/.+"), "/home/test/.espressif/tools/esp-clang/esp-20.1.1_20250829/esp-clang/bin/clangd")
  expect.equality(clangd:match("esp%-20%.1%.1_20250829"), "esp-20.1.1_20250829")
  expect.equality(clangd:match("esp%-clang/bin/clangd$"), "esp-clang/bin/clangd")
  vim.env.HOME = previous_home
end

T["find_esp_clangd() honors IDF_TOOLS_PATH"] = function()
  prepare_case()
  vim.env.IDF_TOOLS_PATH = "/custom/espressif/tools"

  set_scandir({
    ["/custom/espressif/tools/esp-clang"] = {
      "esp-19.1.2_20231212",
      "esp-20.1.1_20250829",
    },
  })

  vim.fn.executable = function(path)
    if path == "clangd" then
      return 0
    end
    return 1
  end

  local esp32 = load_module()
  reset_plugin_state(esp32)

  expect.equality(
    esp32.find_esp_clangd(),
    "/custom/espressif/tools/esp-clang/esp-20.1.1_20250829/esp-clang/bin/clangd"
  )
end

T["find_esp_clangd() honors a classic IDF_TOOLS_PATH pointing at the .espressif root"] = function()
  prepare_case()
  vim.env.IDF_TOOLS_PATH = "/custom/espressif"

  set_scandir({
    ["/custom/espressif/tools/esp-clang"] = {
      "esp-20.1.1_20250829",
    },
  })

  vim.fn.executable = function(path)
    if path == "clangd" then
      return 0
    end
    return 1
  end

  local esp32 = load_module()
  reset_plugin_state(esp32)

  expect.equality(
    esp32.find_esp_clangd(),
    "/custom/espressif/tools/esp-clang/esp-20.1.1_20250829/esp-clang/bin/clangd"
  )
end

T["find_esp_clangd() falls back to the Windows EIM tools dir"] = function()
  prepare_case()
  local previous_has = vim.fn.has
  vim.fn.has = function(feature)
    if feature == "win32" then
      return 1
    end
    return previous_has(feature)
  end

  set_scandir({
    ["C:/Espressif/tools/esp-clang"] = {
      "esp-20.1.1_20250829",
    },
  })

  vim.fn.executable = function(path)
    if path == "clangd" then
      return 0
    end
    return 1
  end

  local esp32 = load_module()
  reset_plugin_state(esp32)
  local clangd = esp32.find_esp_clangd()
  vim.fn.has = previous_has

  expect.equality(clangd, "C:/Espressif/tools/esp-clang/esp-20.1.1_20250829/esp-clang/bin/clangd")
end

T["resolve_idf_cmd() uses the Scripts python interpreter on Windows"] = function()
  prepare_case()
  local previous_has = vim.fn.has
  vim.fn.has = function(feature)
    if feature == "win32" then
      return 1
    end
    return previous_has(feature)
  end
  vim.env.IDF_PATH = "C:/Espressif/frameworks/esp-idf-v6.0.2"
  vim.env.IDF_PYTHON_ENV_PATH = "C:/Espressif/python_env/idf6.0_py3.11_env"

  vim.fn.executable = function(path)
    return path == "C:/Espressif/python_env/idf6.0_py3.11_env/Scripts/python.exe" and 1 or 0
  end
  vim.fn.filereadable = function(path)
    return path == "C:/Espressif/frameworks/esp-idf-v6.0.2/tools/idf.py" and 1 or 0
  end

  local esp32 = load_module()
  reset_plugin_state(esp32)
  local cmd = esp32.resolve_idf_cmd()
  vim.fn.has = previous_has

  expect.equality(
    cmd,
    "'C:/Espressif/python_env/idf6.0_py3.11_env/Scripts/python.exe' "
      .. "'C:/Espressif/frameworks/esp-idf-v6.0.2/tools/idf.py'"
  )
end

T["lsp_config() uses build_dir, root markers, and appends clangd_args"] = function()
  prepare_case()
  local esp32_path = "/opt/espressif/clangd"

  vim.fn.executable = function(path)
    if path == "clangd" then
      return 1
    end
    return path == esp32_path and 1 or 0
  end
  vim.fn.system = function()
    return "clangd version espressif"
  end
  vim.fn.exepath = function()
    return esp32_path
  end

  local esp32 = load_module()
  reset_plugin_state(esp32)
  esp32.setup({
    build_dir = "build.custom",
    clangd_args = { "--query-driver=**", "--enable-config" },
  })

  local config = esp32.lsp_config()

  expect.equality(config.cmd[1], esp32_path)
  expect_truthy(vim.tbl_contains(config.cmd, "--compile-commands-dir=build.custom"))
  expect_truthy(vim.tbl_contains(config.cmd, "--function-arg-placeholders=true"))
  expect_truthy(vim.tbl_contains(config.cmd, "--query-driver=**"))
  expect_truthy(vim.tbl_contains(config.cmd, "--enable-config"))
  expect.equality(config.root_markers, { "sdkconfig", "CMakeLists.txt" })
  expect_truthy(config.capabilities ~= nil)
  expect.equality(config.capabilities.general.positionEncodings, { "utf-16" })
end

T["lsp_config() falls back to system clangd and warns when esp clangd is missing"] = function()
  prepare_case()
  local esp32 = load_module()
  reset_plugin_state(esp32)

  local config = esp32.lsp_config()

  expect.equality(config.cmd[1], "clangd")
  expect.equality(#notifications, 1)
  expect.equality(
    notifications[1].message,
    "[ESP32] No esp-clangd found. Falling back to system clangd."
  )
  expect.equality(notifications[1].level, vim.log.levels.WARN)
end

T["setup() merges options and warns when esp clangd is missing"] = function()
  prepare_case()
  local esp32 = load_module()
  reset_plugin_state(esp32)

  esp32.setup({
    build_dir = "build.test",
    clangd_args = { "--query-driver=**" },
  })

  expect.equality(esp32.options.build_dir, "build.test")
  expect.equality(esp32.options.baudrate, 115200)
  expect.equality(esp32.options.clangd_args, { "--query-driver=**" })
  expect.equality(#notifications, 1)
  expect.equality(
    notifications[1].message,
    "[ESP32] ⚠️ ESP-specific clangd not found. LSP may not work properly."
  )
end

T["ensure_compile_commands() warns when compile_commands.json is missing"] = function()
  prepare_case()
  local esp32 = load_module()
  reset_plugin_state(esp32)
  esp32.options.build_dir = "build.missing"

  esp32.ensure_compile_commands()

  expect.equality(#notifications, 1)
  expect.equality(
    notifications[1].message,
    "[ESP32] ⚠️ Missing compile_commands.json in build.missing/compile_commands.json"
  )
  expect.equality(notifications[1].level, vim.log.levels.WARN)
end

T["compile_commands_toolchain() recognises a GCC database"] = function()
  prepare_case()
  local esp32 = load_module()
  reset_plugin_state(esp32)
  set_compile_commands("/opt/espressif/bin/xtensa-esp32-elf-gcc")

  expect.equality(esp32.compile_commands_toolchain(), "gcc")
end

T["compile_commands_toolchain() recognises a clang database"] = function()
  prepare_case()
  local esp32 = load_module()
  reset_plugin_state(esp32)
  set_compile_commands("/opt/espressif/esp-clang/bin/clang")

  expect.equality(esp32.compile_commands_toolchain(), "clang")
end

T["compile_commands_toolchain() returns nil without a database"] = function()
  prepare_case()
  local esp32 = load_module()
  reset_plugin_state(esp32)

  expect.equality(esp32.compile_commands_toolchain(), nil)
end

T["ensure_compile_commands() warns when the database was generated for GCC"] = function()
  prepare_case()
  local esp32 = load_module()
  reset_plugin_state(esp32)
  set_compile_commands("/opt/espressif/bin/riscv32-esp-elf-gcc")

  esp32.ensure_compile_commands()

  expect.equality(#notifications, 1)
  expect_truthy(notifications[1].message:match("generated for the GCC toolchain"))
  expect_truthy(notifications[1].message:match("ESPReconfigure"))
  expect.equality(notifications[1].level, vim.log.levels.WARN)
end

T["ensure_compile_commands() stays quiet for a clang database"] = function()
  prepare_case()
  local esp32 = load_module()
  reset_plugin_state(esp32)
  set_compile_commands("/opt/espressif/esp-clang/bin/clang")

  esp32.ensure_compile_commands()

  expect.equality(#notifications, 0)
end

T["compile_commands_toolchain() resolves build_dir against the project root"] = function()
  prepare_case()
  local esp32 = load_module()
  reset_plugin_state(esp32)

  local checked
  vim.fn.filereadable = function(path)
    checked = path
    return 0
  end

  esp32.compile_commands_toolchain("/project/blink")

  expect.equality(checked, "/project/blink/build.clang/compile_commands.json")
end

T["compile_commands_toolchain() leaves an absolute build_dir alone"] = function()
  prepare_case()
  local esp32 = load_module()
  reset_plugin_state(esp32)
  esp32.options.build_dir = "/elsewhere/build"

  local checked
  vim.fn.filereadable = function(path)
    checked = path
    return 0
  end

  esp32.compile_commands_toolchain("/project/blink")

  expect.equality(checked, "/elsewhere/build/compile_commands.json")
end

T["LspAttach checks the project clangd attached to, once per root"] = function()
  prepare_case()
  local esp32 = load_module()
  reset_plugin_state(esp32)
  set_compile_commands("/opt/espressif/bin/xtensa-esp32-elf-gcc")

  local previous_get_client = vim.lsp.get_client_by_id
  vim.lsp.get_client_by_id = function(id)
    if id == 1 then
      return { name = "clangd", root_dir = "/project/blink" }
    end
    return { name = "lua_ls", root_dir = "/project/blink" }
  end

  esp32.check_attached_client(1)
  esp32.check_attached_client(1)
  esp32.check_attached_client(2)

  vim.lsp.get_client_by_id = previous_get_client

  -- Same root twice and a non-clangd client must not add more warnings.
  expect.equality(#notifications, 1)
  expect_truthy(notifications[1].message:match("generated for the GCC toolchain"))
  expect_truthy(notifications[1].message:match("^%[ESP32%].*/project/blink/build%.clang"))
end

T["make_idf_command() uses the EIM Python environment when idf.py is a shell function"] = function()
  prepare_case()
  vim.env.IDF_PATH = "/home/test/.espressif/v6.0.1/esp-idf/v6.0.1/esp-idf"
  vim.env.IDF_PYTHON_ENV_PATH = "/home/test/.espressif/tools/python/v6.0.1/venv"

  vim.fn.executable = function(path)
    if path == "idf.py" then
      return 0
    end

    return path == "/home/test/.espressif/tools/python/v6.0.1/venv/bin/python" and 1 or 0
  end

  vim.fn.filereadable = function(path)
    return path == "/home/test/.espressif/v6.0.1/esp-idf/v6.0.1/esp-idf/tools/idf.py" and 1 or 0
  end

  local esp32 = load_module()
  reset_plugin_state(esp32)
  esp32.options.build_dir = "build clang"

  expect.equality(
    esp32.make_idf_command("monitor", "/dev/ttyUSB0"),
    "'/home/test/.espressif/tools/python/v6.0.1/venv/bin/python' "
      .. "'/home/test/.espressif/v6.0.1/esp-idf/v6.0.1/esp-idf/tools/idf.py' "
      .. "-B 'build clang' -p '/dev/ttyUSB0' monitor"
  )
end

T["resolve_idf_cmd() does not guess a Python interpreter without IDF_PYTHON_ENV_PATH"] = function()
  prepare_case()
  vim.env.IDF_PATH = "/home/test/.espressif/v6.0.1/esp-idf/v6.0.1/esp-idf"

  vim.fn.executable = function(path)
    return (path == "python3" or path == "python") and 1 or 0
  end

  vim.fn.filereadable = function(path)
    return path == "/home/test/.espressif/v6.0.1/esp-idf/v6.0.1/esp-idf/tools/idf.py" and 1 or 0
  end

  local esp32 = load_module()
  reset_plugin_state(esp32)

  expect.equality(esp32.resolve_idf_cmd(), "idf.py")
end

T["make_idf_command() respects a configured idf_cmd"] = function()
  prepare_case()
  local esp32 = load_module()
  reset_plugin_state(esp32)
  esp32.setup({
    idf_cmd = "/usr/local/bin/idf.py-wrapper",
  })

  expect.equality(
    esp32.make_idf_command("build"),
    "/usr/local/bin/idf.py-wrapper -B 'build.clang' build"
  )
end

T["resolve_idf_cmd() ignores an empty idf_cmd override"] = function()
  prepare_case()
  vim.fn.executable = function(path)
    return path == "idf.py" and 1 or 0
  end

  local esp32 = load_module()
  reset_plugin_state(esp32)
  esp32.setup({
    idf_cmd = "",
  })

  expect.equality(esp32.resolve_idf_cmd(), "idf.py")
end

T["info() reports idf.py available when an EIM Python command can be resolved"] = function()
  prepare_case()
  vim.env.IDF_PATH = "/home/test/.espressif/v6.0.1/esp-idf/v6.0.1/esp-idf"
  vim.env.IDF_PYTHON_ENV_PATH = "/home/test/.espressif/tools/python/v6.0.1/venv"

  vim.fn.executable = function(path)
    if path == "/home/test/.espressif/tools/python/v6.0.1/venv/bin/python" then
      return 1
    end

    return 0
  end

  vim.fn.filereadable = function(path)
    return path == "/home/test/.espressif/v6.0.1/esp-idf/v6.0.1/esp-idf/tools/idf.py" and 1 or 0
  end

  local esp32 = load_module()
  reset_plugin_state(esp32)
  esp32.info()

  expect.equality(#notifications, 1)
  expect.equality(notifications[1].message, table.concat({
    "✗ ESP-specific clangd missing",
    "✗ compile_commands.json missing",
    "✓ idf.py",
    "✗ llvm-ar",
    "IDF_PATH: /home/test/.espressif/v6.0.1/esp-idf/v6.0.1/esp-idf",
  }, "\n"))
end

T["info() reports project and environment status"] = function()
  prepare_case()
  local esp32_path = "/opt/espressif/clangd"

  vim.fn.executable = function(bin)
    if bin == "clangd" then
      return 1
    end
    if bin == "idf.py" or bin == "llvm-ar" then
      return 1
    end
    return 0
  end
  vim.fn.system = function()
    return "clangd version espressif"
  end
  vim.fn.exepath = function()
    return esp32_path
  end
  vim.fn.filereadable = function(path)
    if path == "build.clang/compile_commands.json" then
      return 1
    end
    return 0
  end
  vim.env.IDF_PATH = "/opt/esp-idf"

  local esp32 = load_module()
  reset_plugin_state(esp32)
  esp32.info()

  expect.equality(#notifications, 1)
  expect.equality(notifications[1].level, vim.log.levels.INFO)
  expect.equality(notifications[1].message, table.concat({
    "✓ Found esp-clangd",
    "✓ compile_commands.json exists",
    "✓ idf.py",
    "✓ llvm-ar",
    "IDF_PATH: /opt/esp-idf",
  }, "\n"))
end

T["info() suggests EIM and manual activation when ESP-IDF is not active"] = function()
  prepare_case()
  local esp32 = load_module()
  reset_plugin_state(esp32)
  esp32.info()

  expect.equality(#notifications, 1)
  expect.equality(notifications[1].level, vim.log.levels.INFO)
  expect.equality(notifications[1].message, table.concat({
    "✗ ESP-specific clangd missing",
    "✗ compile_commands.json missing",
    "✗ idf.py",
    "✗ llvm-ar",
    "IDF_PATH: ✗ not set",
    "⚠️ Source an ESP-IDF environment before launching Neovim:",
    "source ~/.espressif/tools/activate_idf_<version>.sh",
    "or source ~/esp/esp-idf/export.sh",
  }, "\n"))
end

T["info() suggests the PowerShell profile on Windows when ESP-IDF is not active"] = function()
  prepare_case()
  local previous_has = vim.fn.has
  vim.fn.has = function(feature)
    if feature == "win32" then
      return 1
    end
    return previous_has(feature)
  end

  local esp32 = load_module()
  reset_plugin_state(esp32)
  esp32.info()
  vim.fn.has = previous_has

  expect.equality(#notifications, 1)
  expect.equality(notifications[1].message, table.concat({
    "✗ ESP-specific clangd missing",
    "✗ compile_commands.json missing",
    "✗ idf.py",
    "✗ llvm-ar",
    "IDF_PATH: ✗ not set",
    "⚠️ Source an ESP-IDF environment before launching Neovim:",
    [[. C:\Espressif\tools\Microsoft.<version>.PowerShell_profile.ps1]],
  }, "\n"))
end

T["module load registers user commands"] = function()
  prepare_case()
  local esp32 = load_module()
  reset_plugin_state(esp32)

  local commands = vim.api.nvim_get_commands({})
  expect.equality(type(esp32.build), "function")
  expect_truthy(commands.ESPBuild ~= nil)
  expect_truthy(commands.ESPReconfigure ~= nil)
  expect_truthy(commands.ESPInfo ~= nil)
end

T["command() reuses the last selected port and toggles monitor sessions"] = function()
  prepare_case()
  local calls = {}
  local esp32 = load_module({
    terminal = {
      open = function(cmd, opts)
        table.insert(calls, { method = "open", cmd = cmd, opts = opts })
      end,
      toggle = function(cmd, opts)
        table.insert(calls, { method = "toggle", cmd = cmd, opts = opts })
      end,
    },
    picker = {
      pick = function() end,
      util = {
        align = function(value)
          return value
        end,
      },
    },
  })

  reset_plugin_state(esp32)
  esp32.state.last_port = "/dev/ttyUSB9"
  esp32.command("monitor")
  esp32.command("flash")

  expect.equality(calls[1].method, "toggle")
  expect.equality(calls[1].cmd, "idf.py -B 'build.clang' -p '/dev/ttyUSB9' monitor")
  expect.equality(calls[2].method, "open")
  expect.equality(calls[2].cmd, "idf.py -B 'build.clang' -p '/dev/ttyUSB9' flash")
end

T["pick() stores the selected port and runs the command with it"] = function()
  prepare_case()
  local picker_spec
  local calls = {}
  local esp32 = load_module({
    terminal = {
      open = function(cmd, opts)
        table.insert(calls, { method = "open", cmd = cmd, opts = opts })
      end,
      toggle = function(cmd, opts)
        table.insert(calls, { method = "toggle", cmd = cmd, opts = opts })
      end,
    },
    picker = {
      pick = function(spec)
        picker_spec = spec
      end,
      util = {
        align = function(value)
          return value
        end,
      },
    },
  })

  reset_plugin_state(esp32)
  esp32.pick("monitor")
  picker_spec.confirm({ close = function() end }, { port = "/dev/ttyACM0" })

  expect.equality(esp32.state.last_port, "/dev/ttyACM0")
  expect.equality(calls[1].method, "toggle")
  expect.equality(calls[1].cmd, "idf.py -B 'build.clang' -p '/dev/ttyACM0' monitor")
end

T["lazy.lua packaged spec exposes expected defaults"] = function()
  prepare_case()
  local spec = dofile("lazy.lua")

  expect.equality(spec.main, "esp32")
  expect_truthy(vim.tbl_contains(spec.dependencies, "folke/snacks.nvim"))
  expect.equality(spec.opts.build_dir, "build.clang")
  expect.equality(spec.keys[1].group, "ESP32")
  expect.equality(spec.specs[1][1], "folke/which-key.nvim")
  expect.equality(spec.specs[1].optional, true)
end

return T
