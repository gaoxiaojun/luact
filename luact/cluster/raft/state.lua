local ffi = require 'ffiex.init'
local actor = require 'luact.actor'
local uuid = require 'luact.uuid'

local memory = require 'pulpo.memory'
local util = require 'pulpo.util'
local exception = require 'pulpo.exception'
local fs = require 'pulpo.fs'
local pbuf = require 'pulpo.pbuf'
local event = require 'pulpo.event'
local _M = {}

-- cdefs
ffi.cdef [[
typedef enum luact_raft_node_kind {
	NODE_FOLLOWER,
	NODE_CANDIDATE,
	NODE_LEADER,
} luact_raft_node_kind_t;
typedef enum luact_raft_system_log_kind {
	SYSLOG_ADD_REPLICA_SET,
	SYSLOG_REMOVE_REPLICA_SET,
} luact_raft_system_log_kind_t;

typedef struct luact_raft_hardstate {
	uint64_t term;
	uint64_t commit_idx; 			//index of highest log entry known to be committed (not equal to be applied to fsm)
	luact_uuid_t vote;				//voted raft actor id (not valid, not voted yet)
} luact_raft_hardstate_t;

typedef struct luact_raft_state {
	//raft state
	luact_raft_hardstate_t current;

	//raft working state
	uint64_t last_applied_idx; 		//index of highest log entry applied to state machine
	luact_uuid_t leader_id; 		// raft actor id of leader
	uint8_t node_kind, padd[3];		// node type (follower/candidate/leader)

	//raft state persist
	luact_rbuf_t logbuf; 			// workmem for packing log data
} luact_raft_state_t;
]]
local NODE_FOLLOWER = ffi.cast('luact_raft_node_kind_t', "NODE_FOLLOWER")
local NODE_CANDIDATE = ffi.cast('luact_raft_node_kind_t', "NODE_CANDIDATE")
local NODE_LEADER = ffi.cast('luact_raft_node_kind_t', "NODE_LEADER")
local SYSLOG_ADD_REPLICA_SET = ffi.cast('luact_raft_system_log_kind_t', "SYSLOG_ADD_REPLICA_SET")
local SYSLOG_REMOVE_REPLICA_SET = ffi.cast('luact_raft_system_log_kind_t', "SYSLOG_REMOVE_REPLICA_SET")


-- luact_raft_hardstate_t
local raft_hardstate_index = {}
local raft_hardstate_mt = {
	__index = raft_hardstate_index
}
function raft_hardstate_index:equals(target)
	return self.term == target.term and self.commit_idx == target.commit_idx and self.vote == target.vote
end
function raft_hardstate_index:copy(target)
	self.term = target.term
	self.commit_idx = target.commit_idx
	self.vote = target.vote
end
function raft_hardstate_index:new_term(term)
	self.term = self.term + 1
	uuid.invalidate(self.vote)
end
ffi.metatype('luact_raft_hardstate_t', raft_hardstate_mt)


-- luact_raft_state_conteinr_t
local raft_state_container_index = {}
local raft_state_container_mt = {
	__index = raft_state_index
}
function raft_state_container_index:init()
	fs.mkdir(self.path) -- create directory if not exists
	self:restore() -- try to recover from previous persist state
	self.fsm:attach()
end
function raft_state_container_index:fin()
	event.destroy(self.ev_log)
	event.destroy(self.ev_close)
	self:stop_replication()
	self.proposal:fin()
	self.wal:fin()
	self.snapshot:fin()
	self.fsm:detach()
end
function raft_state_container_index:quorum()
	local i = 0
	for k,v in pairs(self.replicator) do
		i = i + 1
	end
	if i <= 2 then return i end
	return math.ceil((i + 1) / 2)
end
function raft_state_container_index:write_any_logs(kind, msgid, logs)
	local q = self:quorum()
	logs = self.wal:write(kind, self.state.current.term, logs, msgid)
	for i=1,#logs,1 do
		self.proposals:add(q, logs[i])
	end
	self.ev_log:emit('add')
end
function raft_state_container_index:write_logs(msgid, logs)
	self:write_any_logs(nil, msgid, logs)
end
function raft_state_container_index:write_log(msgid, log)
	self:write_any_logs(nil, msgid, {log})
end
function raft_state_container_index:write_syslog(kind, msgid, log)
	self:write_any_logs(kind, msgid, {log})
end
function raft_state_container_index:read_state()
	self.state.current = self.wal:read_state()
end
function raft_state_container_index:read_replica_set()
	self.replica_set = self.wal:read_replica_set()
end
function raft_state_container_index:set_last_commit_index(idx)
	self.state.current.commit_idx = idx
	self.wal:write_state(self.state.current)
end	
function raft_state_container_index:new_term()
	self.state.current:new_term()
	uuid.invalidate(self.state.leader_id)
	self.wal:write_state(self.state.current)
end
function raft_state_container_index:vote(v)
	if not uuid.valid(self.state.current.vote) then
		self.state.current.vote = v
		self.wal:write_state(self.state.current)
	else
		exception.raise('raft', 'vote already', self.state.vote, votew)
	end
end
function raft_state_container_index:become_leader()
	if self.state.node_kind ~= NODE_CANDIDATE then
		exception.raise('raft', 'invalid state change', 'leader', self.state.node_kind)
	end
	self.state.node_kind = NODE_LEADER
	-- run replicator (and write initial log)
	self:add_replica_set(self.replica_set)
end
function raft_state_container_index:become_candidate()
	if self.state.node_kind ~= NODE_FOLLOWER then
		exception.raise('raft', 'invalid state change', 'candidate', self.state.node_kind)
	end
	self.state.node_kind = NODE_CANDIDATE
	self:new_term()
	self:vote(actor.of(self.actor_body))
	self.actor_body:start_election()
end
function raft_state_container_index:become_follower()
	if self.state.node_kind == NODE_LEADER then
		self:stop_replication()
	end
	self.state.node_kind = NODE_FOLLOWER
end
-- nodes are list of luact_uuid_t
function raft_state_container_index:stop_replication()
	-- even if no leader, try to stop replicaiton
	for machine, reps in pairs(self.replicators) do
		for k,v in pairs(reps) do
			if self.state.node_kind == NODE_LEADER then
				logger.error('bug: no-leader node have valid replicator')
			end
			v:fin()
			reps[k] = nil
		end
	end
end
-- replica_set are list of luact_uuid_t
function raft_state_container_index:add_replica_set(msgid, replica_set)
	if type(replica_set) ~= 'table' then
		replica_set = {replica_set}
	end
	-- preserve replica_ids to logs
	for i = 1,#replica_set do
		local found
		for j = 1,#self.replica_set do
			if self.replica_set[j]:equals(replica_set[i]) then
				found = j
			end
		end
		if not found then
			table.insert(self.replica_set, replica_set[i])
		end
	end
	self.wal:write_replica_set(self.replica_set)
	-- only leader need to setup replication
	if not self:is_leader() then return end
	for i = 1,#replica_set do
		id = replica_set[i]
		local machine, thread = uuid.addr(id), uuid.thread_id(id)
		local m = self.replicators[machine]
		if not m then
			m = {}
			self.replicators[machine] = m
		end
		if not m[thread] then
			-- id is act like actor
			m[thread] = replicator.new(id, self)
		end
	end
	-- append log to replicate configuration change
	self:write_syslog(SYSLOG_ADD_REPLICA_SET, msgid, replica_set)
end
-- replica_set are list of luact_uuid_t
function raft_state_container_index:remove_replica_set(msgid, replica_set)
	if type(replica_set) ~= 'table' then
		replica_set = {replica_set}
	end
	-- preserve replica_ids to logs
	for i = 1,#replica_set do
		local found
		for j = 1,#self.replica_set do
			if self.replica_set[j]:equals(replica_set[i]) then
				found = j
			end
		end
		if not found then
			table.remove(self.replica_set, j)
		end
	end
	self.wal:write_replica_set(self.replica_set)
	-- only leader need to setup replication
	if not self:is_leader() then return end
	for _, id in ipairs(replica_set) do
		local machine, thread = uuid.addr(id), uuid.thread_id(id)
		local m = self.replicators[machine]
		if m then
			m[thread]:fin()
			m[thread] = nil
		end
	end
	-- append log to replicate configuration change
	self:write_syslog(SYSLOG_REMOVE_REPLICA_SET, msgid, replica_set)
end
function raft_state_container_index:leader()
	return self.leader_id
end
function raft_state_container_index:is_leader()
	return self.state.node_kind == NODE_LEADER
end
function raft_state_container_index:is_follower()
	return self.state.node_kind == NODE_FOLLOWER
end
function raft_state_container_index:is_candidate()
	return self.state.node_kind == NODE_CANDIDATE
end
function raft_state_container_index:current_term()
	return self.state.current.term
end
function raft_state_container_index:last_commit_index()
	return self.state.current.commit_idx
end
function raft_state_container_index:last_index()
	return self.wal:last_index()
end
function raft_state_container_index:vote_for()
	return uuid.valid(self.state.current.vote) and self.state.current.vote or nil
end
function raft_state_container_index:snapshot_if_needed()
	if (self.state.last_applied_idx - self.snapshot.writer.last_applied_idx) > self.opts.logsize_snapshot_threshold then
		self:snapshot()
	end
end
-- after replication to majority success, apply called
function raft_state_container_index:commited(log_idx)
	if (log_idx - self:last_commit_index()) ~= 1 then
		exception.raise('fatal', 'invalid log idx', self:last_commit_index(), log_idx)
	end
	self:set_last_commit_index(log_idx)
end
function raft_state_container_index:apply_system(log)
	if log.kind == SYSLOG_ADD_REPLICA_SET then
		self:add_replica_set(log.log)
	elseif log.kind == SYSLOG_REMOVE_REPLICA_SET then
		self:remove_replica_set(log.log)
	else
		logger.warn('invalid raft system log commited', log.kind)
	end
end
function raft_state_container_index:apply(log)
	self.fsm:apply(log.log)
	if (log.index - self.state.last_applied_idx) ~= 1 then
		exception.raise('fatal', 'invalid commited log idx', log.index, self.state.last_applied_idx)
	end		
	self.state.last_applied_idx = log.index
	self:snapshot_if_needed()
end
function raft_state_container_index:restore()
	self:read_state()
	self:read_replica_set()
	local idx = self.snapshot:restore(self.fsm)
	if idx then
		self.wal:restore(idx, fsm)
	end
end
function raft_state_container_index:snapshot()
	local last_snapshot_idx = self.snapshot:write(self.fsm, self.state)
	wal:compact(last_snapshot_idx)
end
function raft_state_container_index:append_param_for(replicator)
	local prev_log_idx, prev_log_term
	if replicator.next_index == 1 then
		prev_log_idx, prev_log_term = 0, 0
	elseif (replicator.next_index - 1) == self.snapshot.writer.last_snapshot_idx then
		prev_log_idx, prev_log_term = self.snapshot:last_index_and_term()
	else
		local log = self.wal:at(replicator.next_index)
		if not log then
			exception.raise('raft', 'invalid', 'next_index', replicator.next_index)
		end
		prev_log_idx = log.index
		prev_log_term = log.term
	end 
	local entries = self.wal:logs_from(prev_log_idx + 1),
	if not entries then return false end
	return 
		self:current_term(), 
		self:leader(),
		prev_log_idx,
		prev_log_term,
		entries,
		self.state.current.commit_idx
end


-- module function
function _M.new(fsm, wal, snapshot, opts)
	local r = setmetatable({
		state = ffi.new('luact_raft_state_t'), 
		proposals = proposal.new(wal, opts.initial_proposal_size), 
		ev_log = event.new(), 
		ev_close = event.new(),
		wal = wal, -- logs index is self.offset_idx to self.offset_idx + #logs - 1
		replicators = {}, -- replicators to replicate logs. initialized and sync'ed by replica_set
		replica_set = {}, -- current replica set. array of actor (luact_uuid_t)
		fsm = fsm, 
		snapshot = snapshot,
		opts = opts or default_opts,
	}, raft_state_container_mt)
	r:init()
	return r
end

return _M
