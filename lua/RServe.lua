RServe_ = {
	type_ = "RServe",
	--- Returns an error message  or a value.
	-- ff an entry is of an incompatible type returns with error.
	-- @arg expression The expression must be passed to R.
	-- @usage import ("rstats")
	-- R = RServe{}
	-- R:evaluate(2)
	evaluate = function(self,expression)
		if type(expression)~="string" then
			incompatibleTypeError(1, "string", expression)
		end
		return luarserveevaluate(self.host, self.port, expression)
	end
}

metaTableRServe_ = {
	__index = RServe_,
	__tostring = _Gtme.tostring
}

--- Type to check the configuration options passed by the modeler. It defines default values ​​
-- and returns unexpected error types or call errors.
-- @arg attrTab.host The host name (optional).
-- @arg attrTab.port The port number (optional).
-- @usage import RServe
-- R1 = RServe{host="name", port=6311}
function RServe(attrTab)
	local host
	local port
	if type(attrTab)~="table" and attrTab~=nil then
		verifyNamedTable(attrTab)
	else
		if type(attrTab)~="table" and attrTab==nil then
			attrTab={host="localhost",port=6311}
			host="localhost"
			port=6311
		else
			if type(attrTab.host)~="string" and attrTab.host~=nil then
				incompatibleTypeError("host", "string", attrTab.host)
			elseif attrTab.host=="localhost" or attrTab.host==nil then
				defaultTableValue(attrTab, "host", "localhost")
				host=attrTab.host
			else
				host=attrTab.host
			end

			if type(attrTab.port)~="number" and attrTab.port then
				incompatibleTypeError("port", "number", attrTab.port)
			elseif attrTab.port==6311 or attrTab.port==nil then
				defaultTableValue(attrTab, "port", 6311)
				port=attrTab.port
			else	
				port=attrTab.port
			end
		end
	end
	setmetatable(attrTab, metaTableRServe_)
	return attrTab
end

local vstruct = require("vstruct")
local socket = require("socket")
local rsconst = require("rsrv")

local tcp = assert(socket.tcp())

local server = {} -- R Server metadata

local QAP1_HEADER_FORMAT = "4*u4"							        -- QAP1 header encoding format
local QAP1_PARAMETER_HEADER_FORMAT = "u1 u3"          -- QAP1 parameter header encoding format
local QAP1_SEXP_HEADER_TYPE_FORMAT = "[1 | b2 u6]"
local QAP1_SEXP_HEADER_LEN_FORMAT = "u3"




-- ***********************************************************
-- PRIVATE
-- ***********************************************************



-------------------------------------
-- Split the given string given the separator. Regular split function does not work on Rserve's string array
-- @param str  string to be splited
-- @param sep  separator character (string)
-------------------------------------
local function splitstring(str, sep)
  local res = {}
  local counter = 1
  local pos = 1
  for i = 1, #str do
    if (string.sub(str, i, i) == sep) then
      res[counter] = string.sub(str, pos, i)
      pos  = i + 1
      counter = counter + 1
    end
  end
  return res
end


-------------------------------------
-- Print the Rserve metadata
-------------------------------------
local function printserverdata()
  --printtable(server)
end


-------------------------------------
-- Retrieve Rserve metadata
-- @param rsserver  Server name or IP address
-- @param rsport    Port number
-- TODO: Error handling, pcall(calltcp() does not work
-------------------------------------
local function getserverdata(rsserver, rsport)
  --local res, s, status, partial = pcall(calltcp(rsserver, rsport, " "))
  -- if res then  print("ERROR: "); return end
  local s, status, partial = calltcp(rsserver, rsport, " ")
  -- parse the answer
  local res = s or partial
  server = luarserveparseids(string.sub(res , 1 , 32), rsserver, rsport)
end


-------------------------------------
-- Build an QAP1 message
-- @param rexp    R expression (string)
-------------------------------------
-- TODO: local function buildstrmsg(rexp)
local function buildstrmsg(rexp)
  -- QAP1 message header
  local command = 3           -- -- command specifies the request or response type.
  local length = (#rexp + 4)  -- length of the message (bits 0-31) -- length specifies the number of bytes belonging to this message (excluding the header)
  local offset = 0            -- offset of the data part --  offset specifies the offset of the data part, where 0 means directly after the header (which is normally the case)
  local length2 = 0           -- length of the message (bits 32-6(24-bit int)  -- length2 high bits of the length (must be 0 if the packet size is smaller than 4GB)
  -- QAP1 data part
  local dptype = 4            -- QAP1_DATATYPES[4] = "DT_STRING"
  local data = {command, length, offset, length2, dptype, #rexp, rexp}
  -- format
  local dp_fmt = "u1 u3 s" .. #rexp
  local fmt = QAP1_HEADER_FORMAT .. " " .. dp_fmt
  return vstruct.write(fmt, " ", data)
end


-------------------------------------
-- Parse the header of a SEXP expression
-- @param str    first 4 bytes of a binary encoded SEXP
-------------------------------------
local function getheader(str)
  if #str < 4 then
    return("ERROR: Invalid header (too short)")
    --return nil
  end
  local header = string.sub(str, 1, 4)
  local type = vstruct.read(QAP1_SEXP_HEADER_TYPE_FORMAT, string.sub(header, 1, 1)) -- type[1] = XT_HAS_ATTR; type[2] = expression type
  local len = vstruct.read(QAP1_SEXP_HEADER_LEN_FORMAT, string.sub(header, 2, 4))
  return({["exptype"] = type[2], ["hasatts"] = type[1], ["explen"] = len[1]})
end


-------------------------------------
-- Parse a SEXP expression
-- @param sexp    binary encoded DT_SEXP
-------------------------------------
local function parsesexp(sexp)
  if #sexp < 4 then
    return("WARNING: Invalid SEXP (too short) - " .. #sexp)
    --return nil
  end
  local sexpexps = {}
  local sexpcounter = 1 -- number of sexp expressions found
  local token = 1
  repeat
    -- get the header
    local header = getheader(string.sub(sexp, token, token + 3))
--print("+++++++++++++++++++"); print(QAP1_XPRESSIONTYPES[header.exptype]); printtable(header)
    token = token + 4 -- move token after the header
    local sexpend = token + header.explen - 1 -- final char of SEXP's content
    if header.hasatts then
      local attheader = getheader(string.sub(sexp, token, token + 3))
      local att = parsesexp(string.sub(sexp, token, token + attheader.explen + 3)) -- recursion -- get the whole inner SEXP, that is, header + content
      token = token + 4 + attheader.explen -- move token after the inner SEXP
      sexpexps[sexpcounter] = att
      sexpcounter = sexpcounter + 1
    end -- if header.hasatts
    -- get the content
    local content = string.sub(sexp, token, sexpend)
    token = sexpend + 1 -- move token to the first byte of the next sexp header
    -- local fmt = getFormat(header.exptype, #content) -- format for parsing binary data
    local data = ""
    if header.exptype == 0 then                               -- XT_NULL
      data = "XT_NULL"
    elseif header.exptype == 3 or header.exptype == 19 then -- XT_STR, XT_SYMNAME
      data = vstruct.read(#content .. "*s", content)
    elseif header.exptype == 16 or header.exptype == 21 or header.exptype == 23
        or header.exptype == 20 or header.exptype == 22 then  -- XT_VECTOR, XT_LIST_TAG, XT_LANG_TAG, XT_LIST_NOTAG, XT_LANG_NOTAG
      data = parsesexp(content)
    elseif header.exptype == 32 then                          -- XT_ARRAY_INT
      local len = #content / 4
      data = vstruct.read(len .. "*u4", content)
    elseif header.exptype == 33 then                          -- XT_ARRAY_DOUBLE
      local len = #content / 8
      data = vstruct.read(len .. "*f8", content)
    elseif header.exptype == 34 then                          -- XT_ARRAY_STR
      data = splitstring(content, string.char(0))
    elseif header.exptype == 36 then                          -- XT_ARRAY_BOOL
      local len = vstruct.read("u4", string.sub(content, 1, 4))[1]
      data = vstruct.read(len .. "*b1", string.sub(content, 5))
    elseif header.exptype == 48 then                          -- XT_UNKNOWN
        data = "XT_UNKNOWN"
    else
      return("ERROR: unknown QAP1 expression type:" .. header.exptype)
      --return nil
    end
    --print("---------------"); if data ~= nil then; print(#data); printtable(data); end; print("---------------")
    sexpexps[sexpcounter] = data
    sexpcounter = sexpcounter + 1
  until token > #sexp
  return(sexpexps)
end



-- ***********************************************************
-- PUBLIC
-- ***********************************************************



-------------------------------------
-- Parse the server's id string
-- @param idstring  Server's id string
-------------------------------------
local function luarserveparseids(idstring, rsserver, rsport)
  local rsid = string.sub(idstring, 1, 4)
  local rspver = string.sub(idstring, 5, 8)
  local rsp = string.sub(idstring, 9, 12)
  local rsatts = string.sub(idstring, 13)
  local server = {serverid = rsid, protocol = rsp, protversion = rspver,
                  attributes = rsatts, host = rsserver, port = rsport}
  return server
end

local function calltcp(rsserver, rsport, msg)
  tcp = socket.tcp() 
  tcp:settimeout(1, 'b')
  tcp:connect(rsserver, rsport)
  if msg and msg ~= " " then
    tcp:send(msg)
  end
  local s, status, partial = tcp:receive('*a')
  tcp:close()
  return s, status, partial
end

local function luarservegetserverid(rsserver, rsport)
  if(#server == 0) then
    getserverdata(rsserver, rsport)
  end
end

-------------------------------------
-- Evaluate R expression
-- @param rexp An R expression
-------------------------------------
function luarserveevaluate(rsserver, rsport, rexp)
  local parameters = {}
  local msgbin = buildstrmsg(rexp)
  local s, status, partial = calltcp(rsserver, rsport, msgbin)
  local res = s or partial
  -- parse message
  local idstring = string.sub(res, 1, 32)
  local qmsg = string.sub(res, 33)
  server = luarserveparseids(string.sub(idstring , 1 , 32), rsserver, rsport) -- updates the server metadata
  -- parse QAP1 message header
  local qmsgheader = vstruct.read(QAP1_HEADER_FORMAT, string.sub(qmsg, 1, 16))
      -- qmsgheader[1] = command
      -- qmsgheader[2] = lenght
      -- qmsgheader[3] = offset
      -- qmsgheader[4] = lenght2
  -- parse QAP1 data
  local qmsgdata = string.sub(qmsg, 17)
  local token = 1 -- track the byte being parsed
  local pcounter = 1 -- parameter counter
  repeat
    -- parse the parameter's head
    local paramheader = vstruct.read(QAP1_PARAMETER_HEADER_FORMAT, string.sub(qmsgdata, token, token + 3))
        -- paramheader[1] = type
        -- paramheader[2] = length
    -- parse the parameter's data
    token = token + 4 -- move token to the first byte of data
    local parambody = string.sub(qmsgdata, token, token + paramheader[2] - 1)
    if paramheader[1] == 1 then                               -- DT_INT
      parameters[pcounter] = vstruct.read("u4", parambody)    -- TODO: test
    elseif paramheader[1] == 3 then                           -- DT_DOUBLE
      parameters[pcounter] = vstruct.read("f4", parambody)    -- TODO: test
    elseif paramheader[1] == 2 or paramheader[1] == 4 then    -- DT_CHAR or DT_STRING
      parameters[pcounter] = vstruct.read("s", parambody)     -- TODO: test
    elseif paramheader[1] == 10 then                          -- DT_SEXP
      parameters[pcounter] = parsesexp(parambody)
    else
      return("ERROR: parameter type " .. paramheader[1] .. " not implemented")
    end
    token = token + paramheader[2] -- move token to the first byte of the next parameter header
    pcounter = pcounter + 1
  until token > qmsgheader[2]
  return(parameters)
end
