--[[
Copyright (c) 2018, Vsevolod Stakhov <vsevolod@highsecure.ru>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]]--

local ansicolors = require "rspamadm/ansicolors"
local local_conf = rspamd_paths['CONFDIR']
local rspamd_util = require "rspamd_util"
local rspamd_logger = require "rspamd_logger"
local lua_util = require "lua_util"
local lua_stat_tools = require "stat_tools"
local lua_redis = require "lua_redis"
local ucl = require "ucl"

local plugins_stat = require "rspamadm/plugins_stats"

local rspamd_logo = [[
  ____                                     _
 |  _ \  ___  _ __    __ _  _ __ ___    __| |
 | |_) |/ __|| '_ \  / _` || '_ ` _ \  / _` |
 |  _ < \__ \| |_) || (_| || | | | | || (_| |
 |_| \_\|___/| .__/  \__,_||_| |_| |_| \__,_|
             |_|
]]

local redis_params

local function printf(fmt, ...)
  io.write(string.format(fmt, ...))
  io.write('\n')
end

local function highlight(str)
  return ansicolors.white .. str .. ansicolors.reset
end

local function ask_yes_no(greet, default)
  local def_str
  if default then
    greet = greet .. "[Y/n]: "
    def_str = "yes"
  else
    greet = greet .. "[y/N]: "
    def_str = "no"
  end

  local reply = rspamd_util.readline(greet)

  if not reply then os.exit(0) end
  if #reply == 0 then reply = def_str end
  reply = reply:lower()
  if reply == 'y' or reply == 'yes' then return true end

  return false
end

local function readline_default(greet, def_value)
  local reply = rspamd_util.readline(greet)
  if not reply then os.exit(0) end

  if #reply == 0 then return def_value end

  return reply
end

local function print_changes(changes)
  local function print_change(k, c, where)
    printf('File: %s, changes list:', highlight(local_conf .. '/'
        .. where .. '/'.. k .. '.conf'))

    for ek,ev in pairs(c) do
      printf("%s => %s", highlight(ek), rspamd_logger.slog("%s", ev))
    end
  end
  for k, v in pairs(changes.l) do
    print_change(k, v, 'local.d')
    if changes.o[k] then
      v = changes.o[k]
      print_change(k, v, 'override.d')
    end
    print()
  end
end

local function apply_changes(changes)
  local function dirname(fname)
    if fname:match(".-/.-") then
      return string.gsub(fname, "(.*/)(.*)", "%1")
    else
      return nil
    end
  end

  local function apply_change(k, c, where)
    local fname = local_conf .. '/' .. where .. '/'.. k .. '.conf'

    if not rspamd_util.file_exists(fname) then
      printf("Create file %s", highlight(fname))

      local dname = dirname(fname)

      if dname then
        local ret, err = rspamd_util.mkdir(dname, true)

        if not ret then
          printf("Cannot make directory %s: %s", dname, highlight(err))
          os.exit(1)
        end
      end
    end

    local f = io.open(fname, "a+")

    if not f then
      printf("Cannot open file %s, aborting", highlight(fname))
      os.exit(1)
    end

    f:write(ucl.to_config(c))

    f:close()
  end
  for k, v in pairs(changes.l) do
    apply_change(k, v, 'local.d')
    if changes.o[k] then
      v = changes.o[k]
      apply_change(k, v, 'override.d')
    end
  end
end


local function setup_controller(controller, changes)
  printf("Setup %s and controller worker:", highlight("WebUI"))

  if not controller.password or controller.password == 'q1' then
    if ask_yes_no("Controller password is not set, do you want to set one?", true) then
      local pw_encrypted = rspamadm.pw_encrypt()
      if pw_encrypted then
        printf("Set encrypted password to: %s", highlight(pw_encrypted))
        changes.l['worker-controller.inc'] = {
          password = pw_encrypted
        }
      end
    end
  end
end

local function setup_redis(cfg, changes)
  local function parse_servers(servers)
    local ls = lua_util.rspamd_str_split(servers, ",")

    return ls
  end

  printf("%s servers are not set:", highlight("Redis"))
  printf("The following modules will be enabled if you add Redis servers:")

  for k,_ in pairs(rspamd_plugins_state.disabled_redis) do
    printf("\t* %s", highlight(k))
  end

  if ask_yes_no("Do you wish to set Redis servers?", true) then
    local read_servers = readline_default("Input read only servers separated by `,` [default: localhost]: ",
      "localhost")

    local rs = parse_servers(read_servers)
    if rs and #rs > 0 then
      changes.l['redis.conf'] = {
        read_servers = table.concat(rs, ",")
      }
    end
    local write_servers = readline_default("Input write only servers separated by `,` [default: "
        .. read_servers .. "]: ", read_servers)

    if not write_servers or #write_servers == 0 then
      printf("Use read servers %s as write servers", highlight(table.concat(rs, ",")))
      write_servers = read_servers
    end

    redis_params = {
      read_servers = rs,
    }

    local ws = parse_servers(write_servers)
    if ws and #ws > 0 then
      changes.l['redis.conf']['write_servers'] = table.concat(ws, ",")
      redis_params['write_servers'] = ws
    end

    if ask_yes_no('Do you have any password set for your Redis?') then
      local passwd = readline_default("Enter Redis password:", nil)

      if passwd then
        changes.l['redis.conf']['password'] = passwd
        redis_params['password'] = passwd
      end
    end

    if ask_yes_no('Do you have any specific database for your Redis?') then
      local db = readline_default("Enter Redis database:", nil)

      if db then
        changes.l['redis.conf']['db'] = db
        redis_params['db'] = db
      end
    end
  end
end

local function setup_dkim_signing(cfg, changes)
  local domains = {}
  local has_domains = false

  local dkim_keys_dir = rspamd_paths["DBDIR"] .. "/dkim/"

  local prompt = string.format("Enter output directory for the keys [default: %s]: ",
    highlight(dkim_keys_dir))
  dkim_keys_dir = readline_default(prompt, dkim_keys_dir)

  local ret, err = rspamd_util.mkdir(dkim_keys_dir, true)

  if not ret then
    printf("Cannot make directory %s: %s", dkim_keys_dir, highlight(err))
    os.exit(1)
  end

  local function print_domains()
    print("Domains configured:")
    for k,v in pairs(domains) do
      printf("Domain: %s, selector: %s, privkey: %s", highlight(k),
          v.selector, v.privkey)
    end
    print("--")
  end

  repeat
    if has_domains then
      print_domains()
    end

    local domain
    repeat
      domain = rspamd_util.readline("Enter domain to sign: ")
      if not domain then
        os.exit(1)
      end
    until #domain ~= 0

    local selector = readline_default("Enter domain to sign [default: dkim]: ", 'dkim')
    if not selector then selector = 'dkim' end

    local privkey_file = string.format("%s/%s.%s.key", dkim_keys_dir, domain,
        selector)
    if not rspamd_util.file_exists(privkey_file) then
      if ask_yes_no("Do you want to create privkey " .. highlight(privkey_file),
        true) then
        local pubkey_file = privkey_file .. ".pub"
        rspamadm.dkim_keygen(domain, selector, privkey_file, pubkey_file, 2048)

        local f = io.open(pubkey_file)
        if not f then
          printf("Cannot open pubkey file %s, fatal error", highlight(pubkey_file))
          os.exit(1)
        end

        local content = f:read("*all")
        f:close()
        print("To make dkim signing working, you need to place the following record in your DNS zone:")
        print(content)
      end
    end

    domains[domain] = {
      selector = selector,
      privkey = privkey_file,
    }
  until not ask_yes_no("Do you wish to add another DKIM domain?")

  changes.l.dkim_signing = {domain = domains}
end

local function parse_time_interval(str)
  local function parse_time_suffix(s)
    if s == 's' then
      return 1
    elseif s == 'm' then
      return 60
    elseif s == 'h' then
      return 3600
    elseif s == 'd' then
      return 86400
    elseif s == 'y' then
      return 365 * 86400;
    end
  end

  local lpeg = require "lpeg"

  local digit = lpeg.R("09")
  local parser = {}
  parser.integer =
  (lpeg.S("+-") ^ -1) *
      (digit   ^  1)
  parser.fractional =
  (lpeg.P(".")   ) *
      (digit ^ 1)
  parser.number =
  (parser.integer *
      (parser.fractional ^ -1)) +
      (lpeg.S("+-") * parser.fractional)
  parser.time = lpeg.Cf(lpeg.Cc(1) *
      (parser.number / tonumber) *
      ((lpeg.S("smhdy") / parse_time_suffix) ^ -1),
    function (acc, val) return acc * val end)

  local t = lpeg.match(parser.time, str)

  return t
end

local function setup_statistic(cfg, changes)
  local sqlite_configs = lua_stat_tools.load_sqlite_config(cfg)

  if #sqlite_configs > 0 then

    if not redis_params then
      printf('You have %d sqlite classifiers, but you have no Redis servers being set',
        #sqlite_configs)
      return false
    end

    local parsed_redis = {}
    if lua_redis.try_load_redis_servers(redis_params, nil, parsed_redis) then
      printf('You have %d sqlite classifiers', #sqlite_configs)
      local expire = readline_default("Expire time for new tokens  [default: 100d]: ",
        '100d')
      expire = parse_time_interval(expire)

      local reset_previous = ask_yes_no("Reset previuous data?")
      if ask_yes_no('Do you wish to convert them to Redis?', true) then

        for _,cls in ipairs(sqlite_configs) do
          if not lua_stat_tools.convert_sqlite_to_redis(parsed_redis, cls.db_spam,
            cls.db_ham, cls.symbol_spam, cls.symbol_ham, cls.learn_cache, expire,
            reset_previous) then
            rspamd_logger.errx('conversion failed')

            return false
          end
          rspamd_logger.messagex('Converted classifier to the from sqlite to redis')
          changes.l['classifier_bayes'] = {
            backend = 'redis',
            new_schema = true,
          }

          if expire then
            changes.l['classifier_bayes'].expire = expire
          end

          if cls.learn_cache then
            changes.l['classifier_bayes'].cache = {
              backend = 'redis'
            }
          end
        end
      end
    end
  end
end

local function find_worker(cfg, wtype)
  if cfg.worker then
    for k,s in pairs(cfg.worker) do
      if type(k) == 'number' and type(s) == 'table' then
        if s[wtype] then return s[wtype] end
      end
      if type(s) == 'table' and s.type and s.type == wtype then
        return s
      end
      if type(k) == 'string' and k == wtype then return s end
    end
  end

  return nil
end



return function(args, cfg)
  local changes = {
    l = {}, -- local changes
    o = {}, -- override changes
  }

  local interactive_start = true
  local checks = {}
  local all_checks = {
    'controller',
    'redis',
    'dkim',
    'statistic',
  }

  if #args > 0 then
    interactive_start = false

    for _,arg in ipairs(args) do
      if arg == 'all' then
        checks = all_checks
      elseif arg == 'list' then
        printf(highlight(rspamd_logo))
        printf('Available modules')
        for _,c in ipairs(all_checks) do
          printf('- %s', c)
        end
        return
      else
        table.insert(checks, arg)
      end
    end
  else
    checks = all_checks
  end

  local function has_check(check)
    for _,c in ipairs(checks) do
      if c == check then
        return true
      end
    end

    return false
  end

  rspamd_util.umask('022')
  if interactive_start then
    printf(highlight(rspamd_logo))
    printf("Welcome to the configuration tool")
    printf("We use %s configuration file, writing results to %s",
      highlight(cfg.config_path), highlight(local_conf))
    plugins_stat(nil, nil)
  end

  if not interactive_start or
      ask_yes_no("Do you wish to continue?", true) then

    if has_check('controller') then
      local controller = find_worker(cfg, 'controller')
      if controller then
        setup_controller(controller, changes)
      end
    end

    if has_check('redis') then
      if not cfg.redis or (not cfg.redis.servers and not cfg.redis.read_servers) then
        setup_redis(cfg, changes)
      else
        redis_params = cfg.redis
      end
    else
      redis_params = cfg.redis
    end

    if has_check('dkim') then
      if cfg.dkim_signing and not cfg.dkim_signing.domain then
        if ask_yes_no('Do you want to setup dkim signing feature?') then
          setup_dkim_signing(cfg, changes)
        end
      end
    end

    if has_check('statistic') then
      setup_statistic(cfg, changes)
    end

    local nchanges = 0
    for _,_ in pairs(changes.l) do nchanges = nchanges + 1 end
    for _,_ in pairs(changes.o) do nchanges = nchanges + 1 end

    if nchanges > 0 then
      print_changes(changes)
      if ask_yes_no("Apply changes?", true) then
        apply_changes(changes)
        printf("%d changes applied, the wizard is finished now", nchanges)
      else
        printf("No changes applied, the wizard is finished now")
      end
    else
      printf("No changes found, the wizard is finished now")
    end
  end
end

