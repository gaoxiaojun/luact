local luact = require 'luact.init'

luact.start({
	datadir = "/tmp/luact",
	n_core = 1, exclusive = true,
	dht = {
		gossip_port = false,	
	}, 
}, function ()
	local luact = require 'luact.init'
	local json = require 'luact.serde.json'
	local uuid = require 'luact.uuid'
	local pbuf = require 'luact.pbuf'
	local common = require 'luact.serde.common'
	local socket = require 'pulpo.socket'

	local memory = luact.memory
	local exception = luact.exception
	local util = luact.util

	-- [[
	local function serde(obj, verify)
		local rb = memory.alloc_typed('luact_rbuf_t')
		rb:init()
		json:pack(rb, obj)
		-- rb:dump()
		local obj2, err = json:unpack(rb)
		if type(err) == 'table' then
			print('unpack error', err)
		end
		rb:fin()
		memory.free(rb)
		if verify then
			assert(verify(obj, obj2))
		else
			logger.report('result', obj, obj2)
			assert(obj == obj2)
		end
	end

	serde(nil)
	serde(true)
	serde(false)
	serde(123)
	serde("hogefuga")
	serde({
		"fuga",
		456,
		false,
		{
			1,2,3,4,5,
		},
	}, util.table_equals)
	serde({
		a = "x",
		b = 123,
		c = false,
		d = {
			1,2,3,4,5,
		},
		e = {
			f = "テスト",
		}
	}, util.table_equals)
--]]
end)

return true