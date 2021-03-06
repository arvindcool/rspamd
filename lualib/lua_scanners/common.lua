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

--[[[
-- @module lua_scanners_common
-- This module contains common external scanners functions
--]]

local rspamd_logger = require "rspamd_logger"
local lua_util = require "lua_util"
local lua_redis = require "lua_redis"

local exports = {}

local function match_patterns(default_sym, found, patterns)
  if type(patterns) ~= 'table' then return default_sym end
  if not patterns[1] then
    for sym, pat in pairs(patterns) do
      if pat:match(found) then
        return sym
      end
    end
    return default_sym
  else
    for _, p in ipairs(patterns) do
      for sym, pat in pairs(p) do
        if pat:match(found) then
          return sym
        end
      end
    end
    return default_sym
  end
end

local function yield_result(task, rule, vname, N)
  local all_whitelisted = true
  if type(vname) == 'string' then
    local symname = match_patterns(rule['symbol'], vname, rule['patterns'])
    if rule['whitelist'] and rule['whitelist']:get_key(vname) then
      rspamd_logger.infox(task, '%s: "%s" is in whitelist', rule['type'], vname)
      return
    end
    task:insert_result(symname, 1.0, vname)
    rspamd_logger.infox(task, '%s: virus found: "%s"', rule['type'], vname)
  elseif type(vname) == 'table' then
    for _, vn in ipairs(vname) do
      local symname = match_patterns(rule['symbol'], vn, rule['patterns'])
      if rule['whitelist'] and rule['whitelist']:get_key(vn) then
        rspamd_logger.infox(task, '%s: "%s" is in whitelist', rule['type'], vn)
      else
        all_whitelisted = false
        task:insert_result(symname, 1.0, vn)
        rspamd_logger.infox(task, '%s: virus found: "%s"', rule['type'], vn)
      end
    end
  end
  if rule['action'] then
    if type(vname) == 'table' then
      if all_whitelisted then return end
      vname = table.concat(vname, '; ')
    end
    task:set_pre_result(rule['action'],
        lua_util.template(rule.message or 'Rejected', {
          SCANNER = rule['type'],
          VIRUS = vname,
        }), N)
  end
end

local function message_not_too_large(task, content, rule)
  local max_size = tonumber(rule.max_size)
  if not max_size then return true end
  if #content > max_size then
    rspamd_logger.infox(task, "skip %s AV check as it is too large: %s (%s is allowed)",
        rule.type, #content, max_size)
    return false
  end
  return true
end

local function need_av_check(task, content, rule)
  return message_not_too_large(task, content, rule)
end

local function check_av_cache(task, digest, rule, fn, N)
  local key = digest

  local function redis_av_cb(err, data)
    if data and type(data) == 'string' then
      -- Cached
      if data ~= 'OK' then
        lua_util.debugm(N, task, 'got cached result for %s: %s',
            key, data)
        data = lua_util.str_split(data, '\v')
        yield_result(task, rule, data, N)
      else
        lua_util.debugm(N, task, 'got cached result for %s: %s',
            key, data)
      end
    else
      if err then
        rspamd_logger.errx(task, 'got error checking cache: %s', err)
      end
      fn()
    end
  end

  if rule.redis_params then

    key = rule['prefix'] .. key

    if lua_redis.redis_make_request(task,
        rule.redis_params, -- connect params
        key, -- hash key
        false, -- is write
        redis_av_cb, --callback
        'GET', -- command
        {key} -- arguments)
    ) then
      return true
    end
  end

  return false
end

local function save_av_cache(task, digest, rule, to_save, N)
  local key = digest

  local function redis_set_cb(err)
    -- Do nothing
    if err then
      rspamd_logger.errx(task, 'failed to save virus cache for %s -> "%s": %s',
          to_save, key, err)
    else
      lua_util.debugm(N, task, 'saved cached result for %s: %s',
          key, to_save)
    end
  end

  if type(to_save) == 'table' then
    to_save = table.concat(to_save, '\v')
  end

  if rule.redis_params then
    key = rule['prefix'] .. key

    lua_redis.redis_make_request(task,
        rule.redis_params, -- connect params
        key, -- hash key
        true, -- is write
        redis_set_cb, --callback
        'SETEX', -- command
        { key, rule['cache_expire'], to_save }
    )
  end

  return false
end

exports.yield_result = yield_result
exports.match_patterns = match_patterns
exports.need_av_check = need_av_check
exports.check_av_cache = check_av_cache
exports.save_av_cache = save_av_cache

setmetatable(exports, {
  __call = function(t, override)
    for k, v in pairs(t) do
      if _G[k] ~= nil then
        local msg = 'function ' .. k .. ' already exists in global scope.'
        if override then
          _G[k] = v
          print('WARNING: ' .. msg .. ' Overwritten.')
        else
          print('NOTICE: ' .. msg .. ' Skipped.')
        end
      else
        _G[k] = v
      end
    end
  end,
})

return exports