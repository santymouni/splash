--
-- This modules provides utilities to access Python
-- objects from Lua. It should be used together with
-- utilities in qtrender_lua.
--


-- This function works very much like standard Lua assert, but:
--
-- * the first argument is the stack level to report the error at (1 being
--   current level, like for `error` function)
-- * it strips the flag if it evaluates to true
-- * it does not take a message parameter and thus will always preserve all
--   elements of the tuple
--
local function assertx(nlevels, ok, ...)
  if not ok then
    -- print("Assertx nlevels=", nlevels, "tb: ", debug.traceback())
    local msg = tostring(select(1, ...))
    error(msg, 1 + nlevels)
  else
    return ...
  end
end


-- Python Splash commands return
--
--   designator, [ result1, result2, ... ]
--
-- tuples.  Designator can be one of the following:
--
--   * "result": return [ result1, result2, ... ]
--
--   * "ok": return true, [ result1, result2, ... ]
--
--   * "not_ok": return nil, [ result1, result2, ... ]
--
--   * "raise": raise error([ result1, result2, ... ])
--
local function unwrap_python_result(error_nlevels, designator, ...)
  if designator == 'result' then
    return ...
  elseif designator == 'ok' then
    return true, ...
  elseif designator == 'not_ok' then
    return nil, ...
  elseif designator == 'raise' then
    -- debug = require "debug"
    assertx(error_nlevels, nil, ...)
  else
    error('Unexpected designator: ' .. tostring(designator))
  end
end


local function unwraps_python_result(func, nlevels)
  if nlevels == nil then
    -- nlevels is passed straight to the corresponding assertx func.
    nlevels = 1
  end
  return function(...)
    return unwrap_python_result(1 + nlevels, func(...))
  end
end


--
-- Python methods don't want explicit 'self' argument;
-- this decorator adds a dummy 'self' argument to allow Lua
-- methods syntax.
--
local function drops_self_argument(func)
  return function(self, ...)
    return func(...)
  end
end


--
-- This decorator makes function yield the result instead of returning it
--
local function yields_result(func)
  return function(...)
    local f = function(...)
      return coroutine.yield(func(...))
    end
    return assertx(2, pcall(f, ...))
  end
end


--
-- A decorator that fixes an issue with passing callbacks from Lua to Python
-- by putting the callback to a table provided by the caller.
-- See https://github.com/scoder/lupa/pull/49 for more.
--
local function sets_callback(func, storage)
  return function(cb, ...)
    storage[1] = cb
    return func(...)
  end
end


local PRIVATE_PREFIX = "private_"

local function is_private_name(key)
  return string.find(key, "^" .. PRIVATE_PREFIX) ~= nil
end


--
-- Create a Lua wrapper for a Python object.
--
-- * Lua methods are created for Python methods wrapped in @command.
-- * Async methods are wrapped with `coroutine.yield`.
-- * Lua <-> Python error handling is fixed.
-- * Private methods are stored in `private_self`, public methods are
--   stored in `self`.
--
local function setup_commands(py_object, self, private_self, async)
  -- Create lua_object:<...> methods from py_object methods:
  for key, opts in pairs(py_object.commands) do
    local command = py_object[key]

    if opts.sets_callback then
      command = sets_callback(command, py_object.tmp_storage)
    end

    -- if opts.pack_results then
    --   command = pack_callback_return_value(command)
    -- end

    command = drops_self_argument(command)

    if opts.unwrap_python_result then
      local nlevels = 1
      if is_private_name(key) then
        -- private functions are wrapped, so nlevels is set to 2 to show error
        -- line number in user code
        nlevels = 2
      end
      command = unwraps_python_result(command, nlevels)
    end

    if async then
      if opts.is_async then
        command = unwraps_python_result(yields_result(command), 1)
      end
    end

    if is_private_name(key) then
      local short_key = string.sub(key, PRIVATE_PREFIX:len() + 1)
      private_self[short_key] = command
    else
      self[key] = command
    end
  end
end


--
-- Handle @lua_property decorators.
--
local function setup_property_access(py_object, self, cls)
  local setters = {}
  local getters = {}
  for name, opts in pairs(py_object.lua_properties) do
    getters[name] = unwraps_python_result(drops_self_argument(py_object[opts.getter]))
    if opts.setter ~= nil then
      setters[name] = unwraps_python_result(drops_self_argument(py_object[opts.setter]))
    else
      setters[name] = function()
        error("Attribute " .. name .. " is read-only.", 2)
      end
    end
  end

  function cls:__newindex(index, value)
    if setters[index] then
      return setters[index](self, value)
    else
      return rawset(cls, index, value)
    end
  end

  function cls:__index(index)
    if getters[index] then
      return getters[index](self)
    else
      return rawget(cls, index)
    end
  end
end


--
-- Create a Lua wrapper for a Python object.
--
local function wrap_exposed_object(py_object, self, cls, private_self, async)
  setup_commands(py_object, self, private_self, async)
  setup_property_access(py_object, self, cls)
end


--
-- Return a metatable for a wrapped Python object
--
local function create_metatable()
  return {
    __wrapped = true
  }
end


--
-- Return true if an object is a wrapped Python object
--
local function is_wrapped(obj)
  local mt = getmetatable(obj)
  if type(mt) ~= 'table' then
    return false
  end
  return mt.__wrapped == true
end


-- Exposed API
return {
  assertx = assertx,
  unwraps_python_result = unwraps_python_result,
  drops_self_argument = drops_self_argument,
  raises_async = raises_async,
  yields_result = yields_result,
  sets_callback = sets_callback,
  is_private_name = is_private_name,
  setup_commands = setup_commands,
  setup_property_access = setup_property_access,
  wrap_exposed_object = wrap_exposed_object,
  create_metatable = create_metatable,
  is_wrapped = is_wrapped,
}
