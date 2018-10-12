-- Copyright (C) Mashape, Inc.
local ffi = require "ffi"
local cjson = require "cjson"
local system_constants = require "lua_system_constants"
local serializer = require "kong.plugins.file-log-extended.serializer"
local BasePlugin = require "kong.plugins.base_plugin"
local req_read_body = ngx.req.read_body
local req_get_body_data = ngx.req.get_body_data

local ngx_timer = ngx.timer.at
local string_len = string.len
local O_CREAT = system_constants.O_CREAT()
local O_WRONLY = system_constants.O_WRONLY()
local O_APPEND = system_constants.O_APPEND()
local S_IRUSR = system_constants.S_IRUSR()
local S_IWUSR = system_constants.S_IWUSR()
local S_IRGRP = system_constants.S_IRGRP()
local S_IROTH = system_constants.S_IROTH()

local oflags = bit.bor(O_WRONLY, O_CREAT, O_APPEND)
local mode = bit.bor(S_IRUSR, S_IWUSR, S_IRGRP, S_IROTH)

ffi.cdef[[
int open(char * filename, int flags, int mode);
int write(int fd, void * ptr, int numbytes);
char *strerror(int errnum);
]]

-- fd tracking utility functions
local file_descriptors = {}

local function get_fd(conf_path)
  return file_descriptors[conf_path]
end

local function set_fd(conf_path, file_descriptor)
  file_descriptors[conf_path] = file_descriptor
end

local function string_to_char(str)
  return ffi.cast("uint8_t*", str)
end

-- Log to a file. Function used as callback from an nginx timer.
-- @param `premature` see OpenResty `ngx.timer.at()`
-- @param `conf`     Configuration table, holds http endpoint details
-- @param `message`  Message to be logged
local function log(premature, conf, message)
  if premature then return end

  local msg = cjson.encode(message).."\n"

  local fd = get_fd(conf.path)
  if not fd then
    fd = ffi.C.open(string_to_char(conf.path), oflags, mode)
    if fd < 0 then
      local errno = ffi.errno()
      ngx.log(ngx.ERR, "[file-log-extended] failed to open the file: ", ffi.string(ffi.C.strerror(errno)))
    else
      set_fd(conf.path, fd)
    end
  end

  ffi.C.write(fd, string_to_char(msg), string_len(msg))
end

local FileLogExtendedHandler = BasePlugin:extend()

FileLogExtendedHandler.PRIORITY = 1

function FileLogExtendedHandler:new()
  FileLogExtendedHandler.super.new(self, "file-log-extended")
end

function FileLogExtendedHandler:access(conf)
  FileLogExtendedHandler.super.access(self)


  ngx.ctx.file_log_extended = { req_body = "", res_body = "" }
  if conf.log_bodies then
    req_read_body()
    ngx.ctx.file_log_extended.req_body = req_get_body_data()
  end
end

function FileLogExtendedHandler:body_filter(conf)
  FileLogExtendedHandler.super.body_filter(self)

  if conf.log_bodies then
    local chunk = ngx.arg[1]
    local res_body = ngx.ctx.file_log_extended and ngx.ctx.file_log_extended.res_body or ""
    res_body = res_body .. (chunk or "")
    ngx.ctx.file_log_extended.res_body = res_body
  end
end

function FileLogExtendedHandler:log(conf)
  FileLogExtendedHandler.super.log(self)
  local message = serializer.serialize(ngx)

  local ok, err = ngx_timer(0, log, conf, message)
  if not ok then
    ngx.log(ngx.ERR, "[file-log-extended] failed to create timer: ", err)
  end

end

return FileLogExtendedHandler