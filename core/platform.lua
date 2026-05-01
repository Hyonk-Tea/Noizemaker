local M = {}

local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_slashes(path)
    local normalized = tostring(path or ""):gsub("\\", "/")
    return normalized:gsub("/+", "/")
end

local function command_ok(result)
    if result == true then
        return true
    end
    if type(result) == "number" then
        return result == 0
    end
    return false
end

local function sh_quote(text)
    return "'" .. tostring(text or ""):gsub("'", "'\\''") .. "'"
end

local function cmd_quote(text)
    return '"' .. tostring(text or ""):gsub('"', '""') .. '"'
end

local function shell_quote(text)
    if IS_WINDOWS then
        return cmd_quote(text)
    end
    return sh_quote(text)
end

local function read_command(command)
    local pipe = io.popen(command, "r")
    if not pipe then
        return nil
    end
    local output = pipe:read("*a")
    pipe:close()
    return output or ""
end

local function run_status(command)
    return command_ok(os.execute(command))
end

local function split_lines(text)
    local lines = {}
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local value = trim(line)
        if value ~= "" then
            lines[#lines + 1] = value
        end
    end
    return lines
end

local function choose_dialog_backend()
    if IS_WINDOWS then
        return "powershell"
    end
    if M.command_exists("zenity") then
        return "zenity"
    end
    if M.command_exists("kdialog") then
        return "kdialog"
    end
    return nil
end

local function run_powershell(script)
    local command = 'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' .. script:gsub('"', '\\"') .. '"'
    local output = read_command(command)
    if not output then
        return nil
    end
    output = trim(output)
    if output == "" then
        return nil
    end
    return output
end

local function choose_folder_powershell(initial_path)
    local script = {
        "Add-Type -AssemblyName System.Windows.Forms",
        "$dialog = New-Object System.Windows.Forms.FolderBrowserDialog",
        "$dialog.Description = 'Select your Space Channel 5 Part 2 root directory'",
    }
    if initial_path and initial_path ~= "" then
        script[#script + 1] = "$dialog.SelectedPath = '" .. tostring(initial_path):gsub("'", "''") .. "'"
    end
    script[#script + 1] = "$dialog.ShowNewFolderButton = $false"
    script[#script + 1] = "if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; Write-Output $dialog.SelectedPath }"
    return run_powershell(table.concat(script, "; "))
end

local function choose_file_powershell(title, filter, initial_dir)
    local script = {
        "Add-Type -AssemblyName System.Windows.Forms",
        "$dialog = New-Object System.Windows.Forms.OpenFileDialog",
        "$dialog.Title = '" .. tostring(title or ""):gsub("'", "''") .. "'",
        "$dialog.Filter = '" .. tostring(filter or "All files (*.*)|*.*"):gsub("'", "''") .. "'",
        "$dialog.CheckFileExists = $true",
        "$dialog.Multiselect = $false",
    }
    if initial_dir and initial_dir ~= "" then
        script[#script + 1] = "$dialog.InitialDirectory = '" .. tostring(initial_dir):gsub("'", "''") .. "'"
    end
    script[#script + 1] = "if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; Write-Output $dialog.FileName }"
    return run_powershell(table.concat(script, "; "))
end

local function choose_save_powershell(title, filter, initial_dir, suggested_name)
    local script = {
        "Add-Type -AssemblyName System.Windows.Forms",
        "$dialog = New-Object System.Windows.Forms.SaveFileDialog",
        "$dialog.Title = '" .. tostring(title or ""):gsub("'", "''") .. "'",
        "$dialog.Filter = '" .. tostring(filter or "All files (*.*)|*.*"):gsub("'", "''") .. "'",
        "$dialog.OverwritePrompt = $true",
        "$dialog.AddExtension = $true",
    }
    if initial_dir and initial_dir ~= "" then
        script[#script + 1] = "$dialog.InitialDirectory = '" .. tostring(initial_dir):gsub("'", "''") .. "'"
    end
    if suggested_name and suggested_name ~= "" then
        script[#script + 1] = "$dialog.FileName = '" .. tostring(suggested_name):gsub("'", "''") .. "'"
    end
    script[#script + 1] = "if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; Write-Output $dialog.FileName }"
    return run_powershell(table.concat(script, "; "))
end

local function prompt_text_powershell(title, prompt, default_value)
    local script = {
        "Add-Type -AssemblyName Microsoft.VisualBasic",
        "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8",
        "$value = [Microsoft.VisualBasic.Interaction]::InputBox('" .. tostring(prompt or ""):gsub("'", "''") .. "', '" .. tostring(title or ""):gsub("'", "''") .. "', '" .. tostring(default_value or ""):gsub("'", "''") .. "')",
        "if ($value -ne '') { Write-Output $value }",
    }
    return run_powershell(table.concat(script, "; "))
end

function M.command_exists(name)
    if IS_WINDOWS then
        return run_status("where " .. tostring(name) .. " >NUL 2>NUL")
    end
    return run_status("command -v " .. sh_quote(name) .. " >/dev/null 2>&1")
end

function M.is_windows()
    return IS_WINDOWS
end

function M.normalize_slashes(path)
    return normalize_slashes(path)
end

function M.shell_quote(text)
    return shell_quote(text)
end

function M.ensure_dir(path)
    if not path or path == "" then
        return false
    end
    if IS_WINDOWS then
        return run_status("if not exist " .. cmd_quote(path) .. " mkdir " .. cmd_quote(path))
    end
    return run_status("mkdir -p " .. sh_quote(path))
end

function M.remove_dir(path)
    if not path or path == "" then
        return false
    end
    if IS_WINDOWS then
        return run_status("if exist " .. cmd_quote(path) .. " rmdir /s /q " .. cmd_quote(path))
    end
    return run_status("rm -rf " .. sh_quote(path))
end

function M.remove_file(path)
    if not path or path == "" then
        return false
    end
    if IS_WINDOWS then
        return run_status("if exist " .. cmd_quote(path) .. " del /f /q " .. cmd_quote(path))
    end
    return run_status("rm -f " .. sh_quote(path))
end

function M.directory_exists(path)
    if not path or path == "" then
        return false
    end
    if IS_WINDOWS then
        return run_status("if exist " .. cmd_quote(path .. "\\*") .. " (exit /b 0) else (exit /b 1)")
    end
    return run_status("[ -d " .. sh_quote(path) .. " ]")
end

function M.list_directories(path)
    local command
    if IS_WINDOWS then
        command = 'dir /b /ad ' .. cmd_quote(path) .. ' 2>NUL'
    else
        command = 'find ' .. sh_quote(path) .. " -mindepth 1 -maxdepth 1 -type d -exec basename {} \\; 2>/dev/null"
    end
    local output = read_command(command)
    if not output then
        return {}
    end
    local items = split_lines(output)
    table.sort(items, function(a, b)
        return a:lower() < b:lower()
    end)
    return items
end

function M.list_files_recursive(path)
    local output
    if IS_WINDOWS then
        output = read_command('dir /b /s /a-d ' .. cmd_quote(path) .. ' 2>NUL')
    else
        output = read_command('find ' .. sh_quote(path) .. " -type f 2>/dev/null")
    end
    if not output then
        return {}
    end

    local root = normalize_slashes(path):gsub("/+$", "")
    local items = {}
    for _, line in ipairs(split_lines(output)) do
        local full = normalize_slashes(line)
        local rel = full
        if full:sub(1, #root) == root then
            rel = full:sub(#root + 1):gsub("^/+", "")
        end
        if rel ~= "" then
            items[#items + 1] = rel
        end
    end
    table.sort(items, function(a, b)
        return a:lower() < b:lower()
    end)
    return items
end

function M.archive_entries(zip_path)
    local output
    if M.command_exists("unzip") then
        output = read_command("unzip -Z1 " .. shell_quote(zip_path) .. " 2>/dev/null")
    elseif M.command_exists("tar") then
        output = read_command("tar -tf " .. shell_quote(zip_path) .. " 2>/dev/null")
    end

    if not output then
        return {}
    end

    local entries = {}
    for _, line in ipairs(split_lines(output)) do
        local value = normalize_slashes(line):gsub("/+$", "")
        if value ~= "" then
            if output:find("^%s*Date%s+Time") or value:match("^%d%d%d%d%-%d%d%-%d%d") then
                local name = value:match("%S+$")
                if name and name ~= "" then
                    value = normalize_slashes(name):gsub("/+$", "")
                end
            end
            entries[#entries + 1] = value
        end
    end
    return entries
end

function M.extract_archive(zip_path, destination)
    if not M.remove_dir(destination) and M.directory_exists(destination) then
        return false
    end
    if not M.ensure_dir(destination) then
        return false
    end

    if M.command_exists("unzip") then
        return run_status("unzip -qq " .. shell_quote(zip_path) .. " -d " .. shell_quote(destination))
    end
    if M.command_exists("tar") then
        return run_status("tar -xf " .. shell_quote(zip_path) .. " -C " .. shell_quote(destination))
    end
    return false
end

function M.choose_folder(initial_path)
    local backend = choose_dialog_backend()
    if backend == "powershell" then
        return choose_folder_powershell(initial_path)
    end
    if backend == "zenity" then
        return trim(read_command("zenity --file-selection --directory --title=" .. sh_quote("Select your Space Channel 5 Part 2 root directory") .. (initial_path and initial_path ~= "" and (" --filename=" .. sh_quote(initial_path .. "/")) or "") .. " 2>/dev/null"))
    end
    if backend == "kdialog" then
        return trim(read_command("kdialog --getexistingdirectory " .. sh_quote(initial_path or ".") .. " --title " .. sh_quote("Select your Space Channel 5 Part 2 root directory") .. " 2>/dev/null"))
    end
    return nil
end

function M.choose_open_file(title, filter, initial_dir)
    local backend = choose_dialog_backend()
    if backend == "powershell" then
        return choose_file_powershell(title, filter, initial_dir)
    end
    if backend == "zenity" then
        return trim(read_command("zenity --file-selection --title=" .. sh_quote(title or "Open file") .. (initial_dir and initial_dir ~= "" and (" --filename=" .. sh_quote(initial_dir .. "/")) or "") .. " 2>/dev/null"))
    end
    if backend == "kdialog" then
        local pattern = filter or "*"
        pattern = pattern:gsub("|", "\n")
        return trim(read_command("kdialog --getopenfilename " .. sh_quote(initial_dir or ".") .. " " .. sh_quote(pattern) .. " --title " .. sh_quote(title or "Open file") .. " 2>/dev/null"))
    end
    return nil
end

function M.choose_save_file(title, filter, initial_dir, suggested_name)
    local backend = choose_dialog_backend()
    if backend == "powershell" then
        return choose_save_powershell(title, filter, initial_dir, suggested_name)
    end
    local initial_path = initial_dir or "."
    if suggested_name and suggested_name ~= "" then
        initial_path = initial_path:gsub("[/\\]$", "") .. "/" .. suggested_name
    end
    if backend == "zenity" then
        return trim(read_command("zenity --file-selection --save --confirm-overwrite --title=" .. sh_quote(title or "Save file") .. " --filename=" .. sh_quote(initial_path) .. " 2>/dev/null"))
    end
    if backend == "kdialog" then
        local pattern = filter or "*"
        pattern = pattern:gsub("|", "\n")
        return trim(read_command("kdialog --getsavefilename " .. sh_quote(initial_path) .. " " .. sh_quote(pattern) .. " --title " .. sh_quote(title or "Save file") .. " 2>/dev/null"))
    end
    return nil
end

function M.prompt_text(title, prompt, default_value)
    local backend = choose_dialog_backend()
    if backend == "powershell" then
        return prompt_text_powershell(title, prompt, default_value)
    end
    if backend == "zenity" then
        return trim(read_command("zenity --entry --title=" .. sh_quote(title or "Input") .. " --text=" .. sh_quote(prompt or "") .. " --entry-text=" .. sh_quote(default_value or "") .. " 2>/dev/null"))
    end
    if backend == "kdialog" then
        return trim(read_command("kdialog --inputbox " .. sh_quote(prompt or "") .. " " .. sh_quote(default_value or "") .. " --title " .. sh_quote(title or "Input") .. " 2>/dev/null"))
    end
    return nil
end

return M
