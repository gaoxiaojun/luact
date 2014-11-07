local ffi = require 'ffiex.init'

local clock = require 'luact.clock'

local pulpo = require 'pulpo.init'
local memory = require 'pulpo.memory'
local socket = require 'pulpo.socket'
local exception = require 'pulpo.exception'
local _M = {}
local C = ffi.C

-- constant
_M.THREAD_BIT_SIZE = 12
_M.TIMESTAMP_BIT_SIZE = 42
_M.SERIAL_BIT_SIZE = 64 - (_M.THREAD_BIT_SIZE + _M.TIMESTAMP_BIT_SIZE)
_M.MAX_SERIAL_ID = (bit.lshift(1, _M.SERIAL_BIT_SIZE) - 1)

-- cdefs
ffi.cdef(([[
typedef union luact_uuid {
	struct luact_id_detail {	//luact implementation detail
		uint32_t thread_id:%d; 	//upto 4k core
		uint32_t serial:%d; 	//can generate 1024 actor id/msec/thread
		uint32_t timestamp_hi:%d;	//hi 10 bits of 42bit msec timestamp 
		uint32_t timestamp_lo:32;	//low 32 bits of 42bit msec timestamp 
		uint32_t machine_id:32;	//cluster local ip address
	} detail;
	struct luact_id_tag {
		uint64_t local_id;
		uint32_t machine_id;
	} tag;
	struct luact_id_tag2 {
		uint32_t local_id[2];
		uint32_t machine_id;
	} tag2;
} luact_uuid_t;
]]):format(_M.THREAD_BIT_SIZE, _M.SERIAL_BIT_SIZE, _M.TIMESTAMP_BIT_SIZE - 32))

-- vars
local idgen = {
	seed = ffi.new('luact_uuid_t'), 
	availables = {}, 
	new = function (self)
		if #self.availables > 0 then
			buf = table.remove(self.availables)
		else
			buf = ffi.new('luact_uuid_t') -- because wanna use gc
			buf.detail.machine_id = self.seed.detail.machine_id
			buf.detail.thread_id = self.seed.detail.thread_id
		end
		return buf
	end,
	free = function (self, uuid)
		table.insert(self.availables, uuid)
	end,
}
local epoc

-- local functions
local function msec_timestamp()
	local s,us = pulpo.util.clock_pair()
	return ((s + us / 1000) * 1000) - epoc
end

-- module function 
function _M.initialize(mt, startup_at, local_address)
	epoc = startup_at and tonumber(startup_at) or math.floor(clock.get() * 1000) -- current time in millis
	ffi.metatype('luact_uuid_t', {
		__index = setmetatable({
			__timestamp = function (t) return (epoc + bit.lshift(t.detail.timestamp_hi, 32) + t.detail.timestamp_lo) end,
			__set_timestamp = function (t, tv)
				t.detail.timestamp_hi = tv / (2 ^ 32)
				t.detail.timestamp_lo = tv % 0xFFFFFFFF
			end,
			__thread_id = function (t) return t.detail.thread_id end,
			__local_id = function (t) return t.tag.local_id end,
			__serial = function (t) -- local_id without thread_id
				return bit.bor(bit.lshift(t:__timestamp(), _M.SERIAL_BIT_SIZE), t.detail.serial)
			end,
			__addr = function (t) return t.tag.machine_id end,
			__clone = function (t)
				local buf = idgen:new()
				buf.local_id = t.local_id
				return buf
			end,
		}, mt), 
		__tostring = function (t)
			return _M.tostring(t)
		end,
		__gc = mt and mt.__gc or function (t)
			idgen:free(t)
		end,
	})
	-- initialize id seed
	local node_address = pulpo.shared_memory('luact_machine_id', function ()
		local v = memory.alloc_typed('uint32_t')
		if local_address then
			v[0] = tonumber(local_address, 16)
		else
			local addr = socket.getifaddr(nil, ffi.defs.AF_INET)
			-- print(addr, addr.sa_family, ffi.defs.AF_INET, ffi.defs.AF_INET6)
			assert(addr.sa_family == ffi.defs.AF_INET, 
				exception.new("invalid", "address", "family", addr.sa_family))
			v[0] = socket.htonl(ffi.cast('struct sockaddr_in*', addr).sin_addr.s_addr)
		end
		logger.notice('node_address:', ('%x'):format(v[0]))
		return 'uint32_t', v
	end)
	_M.node_address = node_address[0]
	idgen.seed.detail.machine_id = _M.node_address
	idgen.seed.detail.thread_id = pulpo.thread_id
	_M.uuid_work.detail.machine_id = _M.node_address
	-- TODO : register machine_id/ip address pair to consul.

end

function _M.new()
	if idgen.seed.detail.serial >= _M.MAX_SERIAL_ID then
		local current = idgen.seed:__timestamp()
		repeat
			clock.sleep(0.01)
			idgen.seed:__set_timestamp(msec_timestamp())
		until current ~= idgen.seed:__timestamp()
		idgen.seed.detail.serial = 0
	else
		idgen.seed.detail.serial = idgen.seed.detail.serial + 1
	end
	local buf = idgen:new()
	buf.detail.serial = idgen.seed.detail.serial
	buf:__set_timestamp(msec_timestamp())
	if _M.DEBUG then
		logger.info('new uuid:', buf)--, debug.traceback())
	end
	return buf
end
function _M.from(ptr)
	local p = ffi.cast('luact_uuid_t*', ptr)
	return p:__clone()
end
function _M.owner_of(uuid)
	return uuid:__addr() == _M.node_address
end
local uuid_work = ffi.new('luact_uuid_t')
_M.uuid_work = uuid_work
function _M.owner_thread_of(uuid_local_id)
	uuid_work.tag.local_id = uuid_local_id
	return uuid_work:__thread_id() == pulpo.thread_id
end
function _M.serial_from_local_id(uuid_local_id)
	uuid_work.tag.local_id = uuid_local_id
	return uuid_work:__serial()
end
function _M.from_local_id(uuid_local_id)
	uuid_work.tag.local_id = uuid_local_id
	return uuid_work
end
function _M.free(uuid)
	idgen:free(uuid)
end

local sprintf_workmem_size = 32
local sprintf_workmem = memory.alloc_typed('char', sprintf_workmem_size)
function _M.tostring(uuid)
	return ('%08x:%08x:%08x'):format(uuid.tag2.local_id[0], uuid.tag2.local_id[1], uuid.tag.machine_id)
end

return _M
