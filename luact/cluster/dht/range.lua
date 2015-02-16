local luact = require 'luact.init'
local uuid = require 'luact.uuid'
local clock = require 'luact.clock'
local serde = require 'luact.serde'
local router = require 'luact.router'
local actor = require 'luact.actor'

local pulpo = require 'pulpo.init'
local event = require 'pulpo.event'
local util = require 'pulpo.util'
local memory = require 'pulpo.memory'
local socket = require 'pulpo.socket'
local tentacle = require 'pulpo.tentacle'
local fs = require 'pulpo.fs'

local raft = require 'luact.cluster.raft'
local key = require 'luact.cluster.dht.key'
local cache = require 'luact.cluster.dht.cache'
local cmd = require 'luact.cluster.dht.cmd'

local storage_module


-- module share variable
local _M = {}
local persistent_db
local root_range
local column_families = {
	lookup = {}
}
local range_caches = {}


-- constant
_M.MAX_BYTE = 64 * 1024 * 1024
_M.INITIAL_BYTE = 1 * 1024 * 1024
_M.DEFAULT_REPLICA = 3
_M.META1_FAMILY = '__meta1__'
_M.META2_FAMILY = '__meta2__'
_M.DEFAULT_FAMILY = '__data__'
_M.KIND_META1 = 1
_M.KIND_META2 = 2
_M.KIND_DEFAULT = 3

_M.SYSKEY_CATEGORY_KIND = 0


-- cdefs
ffi.cdef [[
typedef struct luact_dht_range {
	luact_dht_key_t start_key;
	luact_dht_key_t end_key;
	uint8_t n_replica, kind, padd[2];
	luact_uuid_t replicas[0];		//arbiter actors' uuid
} luact_dht_range_t;
]]


-- common helper
local function make_metakey(kind, key)
	if kind >= _M.KIND_DEFAULT then
		return string.char(kind)..key
	else
		return key
	end
end
-- sys key is stored in root range
local function make_syskey(category, key)
	return '\0'..string.char(kind)..key
end


-- range
local range_mt = {}
range_mt.__index = range_mt
function range_mt.alloc(n_replica)
	local p = ffi.cast('luact_dht_range_t*', 
		memory.alloc(ffi.sizeof('luact_dht_range_t') + (n_replica * ffi.sizeof('luact_uuid_t')))
	)
	p.n_replica = n_replica
	return p
end
function range_mt.fsm_factory(rng)
	return rng
end
function range_mt:init(start_key, end_key, kind)
	self.start_key = start_key
	self.end_key = end_key
	self.kind = kind
end
function range_mt:add_replica(remote)
	remote = remote or actor.root_of()
	self.replica[self.n_replica] = remote.arbiter(self:arbiter_id(), range_mt.fsm_factory, self)
end
function range_mt:fin()
	-- TODO : consider when range need to be removed, and do correct finalization
	assert(false, "TBD")
end
function range_mt:arbiter_id()
	return self:metakey()
end
function range_mt:metakey()
	return make_metakey(self.kind, ffi.string(self.start_key.p, self.start_key.length))
end
function range_mt:check_replica()
	if self.n_replica < _M.NUM_REPLICA then
		exception.raise('invalid', 'dht', 'not enough replica', self.n_replica)
	end
end
-- operation to range
function range_mt:get(k, consistent, timeout)
	return self:rawget(k, #k, consistent, timeout)
end
function range_mt:rawget(k, kl, consistent, timeout)
	self:check_replica()
	return self.replicas[0]:read(cmd.get(self.kind, k, kl), consistent, timeout)
end
function range_mt:put(k, v, timeout)
	return self:rawput(k, #k, v, #v, timeout)
end
function range_mt:rawput(k, kl, v, vl, timeout)
	self:check_replica()
	return self.replicas[0]:write(cmd.put(self.kind, k, kl, v, vl), timeout)
end
function range_mt:merge(k, v, timeout)
	return self:rawmerge(k, #k, v, #v, timeout)
end
function range_mt:rawmerge(k, kl, v, vl, timeout)
	self:check_replica()
	return self.replicas[0]:write(cmd.merge(self.kind, k, kl, v, vl), timeout)
end
function range_mt:cas(k, ov, nv, timeout)
	local oval, ol = ov or nil, ov and #ov or 0
	local nval, nl = nv or nil, nv and #nv or 0
	local cas = storage_module.op_cas(ov, nv, nil, ovl, nvl)
	return self:rawcas(k, #k, oval, ol, nval, nl, timeout)
end
function range_mt:rawcas(k, ov, ovl, nv, nvl, timeout)
	self:check_replica()
	return self.replicas[0]:write(cmd.cas(self.kind, k, kl, ov, ovl, nv, nvl), timeout)
end
function range_mt:watch(k, kl, watcher, method, timeout)
	self:check_replica()
	return self.replicas[0]:write(cmd.watch(self.kind, k, kl, watcher, method), timeout)
end
function range_mt:split(range_key, timeout)
	self:check_replica()
	return self.replicas[0]:write(cmd.split(self.kind, range_key), timeout)
end
-- actual processing on replica node of range
function range_mt:exec_get(storage, k, kl)
	return storage:rawget(k, kl)
end
function range_mt:exec_put(storage, k, kl, v, vl)
	return storage:rawput(k, kl, v, vl)
end
function range_mt:exec_merge(storage, k, kl, v, vl)
	return storage:rawmerge(k, kl, v, vl)
end
range_mt.cas_result = memory.alloc_typed('bool')
function range_mt:exec_cas(storage, k, kl, o, ol, n, nl)
	local cas = storage_module.op_cas(ov, nv, range_mt.cas_result, ovl, nvl)
	storage:rawmerge(k, kl, v, vl, range_mt.sync_write_opts)
	return range_mt.cas_result[0]
end
function range_mt:exec_watch(storage, k, kl, watcher, method, arg, alen)
	assert(false, "TBD")
end
function range_mt:exec_split(storage, k, kl)
	assert(false, "TBD")
end
function range_mt:column_family()
	return column_families[self.kind]
end
-- call from raft module
function range_mt:apply(cmd)
	assert(self.kind == cmd.kind)
	local cf = self:column_family()
	-- TODO : implement various operation
	return cmd:apply_to(cf, self)
end
function range_mt:metadata()
	assert(false, "TBD")
end
function range_mt:snapshot(sr, rb)
	assert(false, "TBD")
end
function range_mt:restore(sr, rb)
	assert(false, "TBD")
end
function range_mt:attach()
	logger.info('range', 'attached')
end
function range_mt:detach()
	logger.info('range', 'detached')
end
ffi.metatype('luact_dht_range_t', range_mt)


-- module functions
function _M.initialize(root, datadir, opts)
	storage_module = require ('luact.cluster.store.'..opts.storage) 
	persistent_db = storage_module.new(datadir, "dht")
	range_mt.sync_write_opts = storage_module.new_write_opts({ sync = true })
	_M.NUM_REPLICA = opts.replica
	if root then -- memorize root_range. all other ranges can be retrieve from it
		root_range = root
	else -- create initial range hirerchy structure manualy 
		local meta2, default, meta2_key, default_key, root_cf, meta2_cf, default_cf
		-- create storage for initial dht setting with bootstrap mode
		root_cf = _M.new_family(_M.KIND_META1, _M.META1_FAMILY, true)
		meta2_cf = _M.new_family(_M.KIND_META2, _M.META2_FAMILY, true)
		default_cf = _M.new_family(_M.KIND_DEFAULT, _M.DEFAULT_FAMILY, true)
		-- create root range
		root_range = _M.new(key.MIN, key.MAX, _M.KIND_META1)
		-- put initial meta2 storage into root_range
		meta2 = _M.new(key.MIN, key.MAX, _M.KIND_META2)
		meta2_key = meta2:metakey()
		root_cf:rawput(meta2_key, #meta2_key, meta2, ffi.sizeof(meta2))
		-- put initial default storage into meta2_range
		default = _M.new(key.MIN, key.MAX, _M.KIND_DEFAULT)
		default_key = default:metakey()
		meta2_cf:rawput(default_key, #default_key, default, ffi.sizeof(default))
	end
end

function _M.new_family(kind, name, cluster_bootstrap)
	if column_families.count >= 255 then
		exception.raise('invalid', 'cannot create new family: full')
	end
	local c = column_families.lookup[name]
	if not c then
		c = persistent_db:column_family(name)
		column_families[kind] = c
		range_caches[kind] = cache.new(kind)
		column_families.lookup[name] = c
	end
	if cluster_bootstrap then
		local syskey = make_syskey(_M.SYSKEY_CATEGORY_KIND, tostring(kind))
		local cas = storage_module.op_cas(nil, name)
		if not c:merge(syskey, cas) then
			exception.raise('fatal', 'initial kind of dht cannot registered', kind, name)
		end
	end
	return c
end

function _M.family_name_by_kind(kind)
	local cf = column_families[kind]
	for k,v in pairs(column_families.lookup) do
		if v == cf then
			return k
		end
	end
	return nil
end

function _M.finalize()
	range_caches = {}
	root_range = nil
	persistent_db:fin()
end

-- create new kind of dht which name is *name*, 
-- it is caller's responsibility to give unique value for *kind*.
-- otherwise it fails.
function _M.bootstrap(kind, name)
	local syskey = make_syskey(_M.SYSKEY_CATEGORY_KIND, tostring(kind))
	if root_range:cas(syskey, nil, name) then
		_M.new_family(id, name)
		local r = _M.new(key.MIN, key.MAX, kind)
		range_caches[kind]:add(r)
		return kind
	end
end

function _M.shutdown(kind, truncate)
	local cf = column_families[kind]
	if cf then
		persistent_db:close_column_family(cf, truncate)
	end
	range_caches[kind] = nil	
end

function _M.new(start_key, end_key, kind)
	kind = kind or _M.KIND_DEFAULT
	local r = range_mt.alloc(_M.NUM_REPLICA)
	r:init(start_key, end_key, kind)
	r:add_replica()
	range_caches[kind]:add(r)
	return r
end

-- find range which contains key (k, kl)
-- search original kind => KIND_META2 => KIND_META1
function _M.find(k, kl, kind)
	kind = kind or _M.KIND_DEFAULT
	local r = range_caches[kind]:find(k, kl)
	if not r then
		k = make_metakey(kind, ffi.string(k, kl))
		kl = #k
		if kind >= _M.KIND_DEFAULT then
			-- make unique key over all key in kind >= _M.KIND_DEFAULT
			if not r then
				-- find range from meta ranges
				r = _M.find(k, kl, _M.KIND_META2)
				if r then
					r = r:rawget(k, kl, true)
				end
			end
		elseif kind > _M.KIND_META1 then
			if not r then
				-- find range from top level meta ranges
				r = _M.find(k, kl, kind - 1)
				if r then
					r = r:rawget(k, kl, true)
				end
			end
		else -- KIND_META1
			r = root_range:rawget(k, kl, true)
		end
		if r then 
			range_caches[kind]:add(r) 
		end
	end
	return r
end

function _M.destroy(r)
	r:fin()
	memory.free(r)
end

return _M
