-- ---------------------------------------------------------------------------
-- x4mp_bridge.lua — C++ → Lua → MD bridge for X4MP smooth movement.
--
-- The x4mp_native.dll raises a Lua event "x4mp_move" every frame with a CSV
-- string payload: "x,y,z,yaw,pitch,roll" (position in sector space, rotation
-- in degrees). This handler parses it and forwards it to MD via
-- AddUITriggeredEvent('X4MP_GhostSync','move',{...}), which MD receives as
-- <event_ui_triggered screen="'X4MP_GhostSync'" control="'move'"/>.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 2026-10-13 移植（v1.2 审查 P2-1）：数值通道统一校验 + 统一错误兜底。
--
-- nums: 字段匹配用的是 `[^,]+`（"不是逗号就行"），所以 "abc,1,2,..." 这类载荷能匹配通过，
-- 但 tonumber() 返回 nil —— nil 进了 AddUITriggeredEvent 的表，MD 侧读到的
-- event.param3.{n} 就是空的，后续算术静默失败、日志里什么都没有。现在任一字段非数字
-- 就整条丢弃并记一条 DebugError，故障从"静默"变"可见"。
-- ---------------------------------------------------------------------------
local function nums(param, ...)
    local t = { }
    for i = 1, select('#', ...) do
        local v = tonumber((select(i, ...)))
        if v == nil then
            pcall(function()
                DebugError("x4mp_bridge: non-numeric field #" .. i .. " in payload: " .. tostring(param))
            end)
            return nil
        end
        t[i] = v
    end
    return t
end

-- safe: X4 的 UI Lua 里任一回调抛错会污染整条事件链，一条 lane 的解析问题不该拖死其余
-- 所有 lane。这里给每个 handler 套一层 pcall；DebugError 自身也再套一层，免得"报错的
-- 动作"本身又抛一次（本文件的 22 个 RegisterEvent 全部改走 safe()）。
local function safe(name, fn)
    return function(event_name, param)
        local ok, err = pcall(fn, event_name, param)
        if not ok then
            pcall(function()
                DebugError("x4mp_bridge: handler " .. name .. " failed: " .. tostring(err))
            end)
        end
    end
end

local function on_move(event_name, param)
    -- X4 RegisterEvent callbacks receive (event_name, param).
    if not param or type(param) ~= "string" then
        return
    end

    local x, y, z, yaw, pitch, roll =
        param:match("^([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)$")
    if not x then
        DebugError("x4mp_bridge: bad payload: " .. tostring(param))
        return
    end

    local nv = nums(param, x, y, z, yaw, pitch, roll) 
    if not nv then return end 
    AddUITriggeredEvent('X4MP_GhostSync', 'move', nv)
end

-- Incoming remote damage: "shieldDamage,hullDamage" in percent points.
-- Forwards to MD <apply_attackstrength> which converts back to absolute.
local function on_damage(event_name, param)
    if not param or type(param) ~= "string" then
        return
    end
    local shield, hull, targetType = param:match("^([^,]+),([^,]+),([^,]+)$")
    if not shield then
        DebugError("x4mp_bridge: bad damage payload: " .. tostring(param))
        return
    end
    local nv = nums(param, shield, hull, targetType) 
    if not nv then return end 
    AddUITriggeredEvent('X4MP_SelfSync', 'damage', nv)
end

-- Remote ship died: blow up the local ghost ship.
local function on_destroy(event_name, param)
    AddUITriggeredEvent('X4MP_GhostSync', 'destroy')
end

-- Host: locally spawn its NPC ships (no payload).
local function on_spawn_npc(event_name, param)
    AddUITriggeredEvent('X4MP_NpcSync', 'spawn')
end

-- Client: recreate an NPC at the position/faction broadcast by the host.
-- 10.8l: the payload also carries the ship's MACRO NAME (field 9) and its rig flags
-- (field 10), so the client builds the same ship the host built instead of choosing
-- one from a pair of literals. Run #14 ended with the host's Xenon I standing next
-- to an S fighter on the client, because the only exception mechanism was a
-- logical-id comparison - and `eq` is not an MD operator.
--
-- 10.8l.7 (run #15, 2026-09-15): the macro name must NOT sit inside the row's table.
-- That is the one thing this round changed and the one thing that was never run: the
-- client received all 131 rows, the DLL raised all 131 of them, and the client's
-- world still stayed empty - MD's `$rmacroName` came out of the table empty (a string
-- element in AddUITriggeredEvent's table does not survive the UI -> MD marshalling),
-- so `'macro.' + $rmacroName` yielded no macro and every create_ship failed in
-- silence (MD debug_text goes nowhere without -logfile). Vanilla never puts a string
-- in that table: it passes ONE value as the 3rd argument -
--   menu_station_configuration.lua:834  AddUITriggeredEvent(menu.name, "moduleadded", macro)
-- read back by MD as
--   x4ep1_mentor_subscription.xml:9564  <set_value name="$SelectMacro" exact="@macro.{event.param3}"/>
-- So the macro travels on its own trigger, ONE call BEFORE the row (MD stores it in
-- global.$X4MPRemoteMacro and the row cue reads it back), and the row's table stays
-- numeric: pose(6) + faction + id + flags = 9 fields.
local function on_spawn_remote(event_name, param)
    if not param or type(param) ~= "string" then
        return
    end
    local x, y, z, yaw, pitch, roll, faction, id, macro, flags =
        param:match("^([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)$")
    if not x then
        DebugError("x4mp_bridge: bad spawn payload: " .. tostring(param))
        return
    end
    -- 1) the out-of-band string (its own trigger, plain string param, vanilla form).
    AddUITriggeredEvent('X4MP_RemoteSync', 'spawnmacro', macro)
    -- 2) the row itself: numbers only (the rig flag moved from field 10 to field 9
    --    when the macro left the table - MD reads event.param3.{9} for it).
    local nv = nums(param, x, y, z, yaw, pitch, roll, faction, id, flags) 
    if not nv then return end 
    AddUITriggeredEvent('X4MP_RemoteSync', 'spawn', nv)
end

-- Client: destroy the local NPC for a despawned logical id.
-- 10.8l.8 (run #16, 2026-09-15): the payload gained a second, numeric field.
--   "lid,silent"   silent=1 -> this despawn clears a puppet the client had NOT built
--                  yet when the host killed it (the host's despawn overtook the row:
--                  the client raises its 131 spawn rows one per frame, ~16 s at the
--                  client's 10-12 fps, and the host's AI kills the Xenon group inside
--                  that window). Such a ship never existed in the client's fight, so
--                  MD must remove it without an explosion.
--   "lid"          the form before 10.8l.8: still accepted, silent defaults to 0.
-- Numbers only, exactly like the spawn row - the 10.8l.7 lesson.
local function on_despawn(event_name, param)
    if not param or type(param) ~= "string" then
        return
    end
    local lid, silent = param:match("^(%d+),(%d+)$")
    if not lid then
        lid    = param:match("^(%d+)$")
        silent = "0"
    end
    if not lid then
        DebugError("x4mp_bridge: bad despawn payload: " .. tostring(param))
        return
    end
    local nv = nums(param, lid, silent) 
    if not nv then return end 
    AddUITriggeredEvent('X4MP_DespawnSync', 'despawn', nv)
end

-- Client: apply damage to the local NPC for a logical id.
local function on_npc_damage(event_name, param)
    if not param or type(param) ~= "string" then
        return
    end
    local lid, hull, shield = param:match("^(%d+),([^,]+),([^,]+)$")
    if not lid then
        DebugError("x4mp_bridge: bad npc damage payload: " .. tostring(param))
        return
    end
    local nv = nums(param, lid, hull, shield) 
    if not nv then return end 
    AddUITriggeredEvent('X4MP_NpcDamageSync', 'damage', nv)
end

-- BOTH PEERS (P0): absolute NPC vitals "logicalID,hullPct,shieldPct".
-- Either value may be -1 ("leave unchanged"); the DLL already decided what is
-- worth writing (it only ever lowers hull/shield), so MD applies it verbatim.
local function on_npc_vitals(event_name, param)
    if not param or type(param) ~= "string" then
        return
    end
    local lid, hull, shield = param:match("^(%d+),([^,]+),([^,]+)$")
    if not lid then
        DebugError("x4mp_bridge: bad npc vitals payload: " .. tostring(param))
        return
    end
    local nv = nums(param, lid, hull, shield) 
    if not nv then return end 
    AddUITriggeredEvent('X4MP_NpcVitalsSync', 'vitals', nv)
end

RegisterEvent("x4mp_move", safe("move", on_move))
RegisterEvent("x4mp_damage", safe("damage", on_damage))
RegisterEvent("x4mp_destroy", safe("destroy", on_destroy))
RegisterEvent("x4mp_spawn_npc", safe("spawn_npc", on_spawn_npc))
RegisterEvent("x4mp_spawn_remote", safe("spawn_remote", on_spawn_remote))
RegisterEvent("x4mp_despawn_remote", safe("despawn", on_despawn))
RegisterEvent("x4mp_npc_damage", safe("npc_damage", on_npc_damage))
RegisterEvent("x4mp_npc_vitals", safe("npc_vitals", on_npc_vitals))

-- BOTH PEERS (P2 v1): behavioural semantics relayed from the host.
-- Payload "logicalID,op,orderIdx,targetLid,targetKind"; op 1 = set_order,
-- 2 = cease (attack stopped). v1 forwards this for display/diagnostics only:
-- making the client's puppet EXECUTE the order would make it shoot for real,
-- and every shot it fires lowers the local copy of the target's hull - a drop
-- the vitals lane would then report to the host as damage the host never took
-- (double damage). See technical doc 3, section 10.8.
local function on_npc_order(event_name, param)
    if not param or type(param) ~= "string" then
        return
    end
    local lid, op, idx, tgt, kind = param:match("^(%d+),(%d+),(%d+),(%d+),(%d+)$")
    if not lid then
        DebugError("x4mp_bridge: bad npc order payload: " .. tostring(param))
        return
    end
    local nv = nums(param, lid, op, idx, tgt, kind) 
    if not nv then return end 
    AddUITriggeredEvent('X4MP_NpcOrderSync', 'order', nv)
end

-- Client: a host NPC fired. Payload "logicalID,targetLid,shots".
-- The DLL coalesces per NPC (at most one row per ~200 ms), so one row means
-- "this NPC is shooting", not "one shot".
local function on_npc_fire(event_name, param)
    if not param or type(param) ~= "string" then
        return
    end
    local lid, tgt, shots = param:match("^(%d+),(%d+),(%d+)$")
    if not lid then
        DebugError("x4mp_bridge: bad npc fire payload: " .. tostring(param))
        return
    end
    local nv = nums(param, lid, tgt, shots) 
    if not nv then return end 
    AddUITriggeredEvent('X4MP_NpcFireSync', 'fire', nv)
end

-- These two must stay BELOW their handler definitions: RegisterEvent takes the
-- function by value, and a file-scope `local function` is not visible before its
-- own definition line (an upvalue that is still nil there, not an error - the
-- registration would silently do nothing).
RegisterEvent("x4mp_npc_order", safe("npc_order", on_npc_order))
RegisterEvent("x4mp_npc_fire", safe("npc_fire", on_npc_fire))

-- 10.8l: the world handshake's last step. The DLL raises this on BOTH peers at
-- the same moment - the host when the client reports that every puppet stands,
-- the client when the host's WORLD_GO arrives - so the A-group Patrol orders and
-- the P1 motion driver start on the same instant on both sides. Until this fires
-- the world exists but does not move: that is what "the host waits for the client"
-- means in practice.
local function on_universe_go(event_name, param)
    AddUITriggeredEvent('X4MP_NpcSync', 'go')
end

RegisterEvent("x4mp_universe_go", safe("universe_go", on_universe_go))
-- Doc 4 (station sync, S4): the host's absolute station state.
-- Payload "idx,hullPct,shieldPct,state"; hull/shield may be -1 ("leave
-- unchanged") and state 3 means "the station is gone on the host" (the MD cue
-- evacuates the hero and destroys the local copy). Numbers only in the table -
-- the same rule the NPC vitals lane follows (doc 3, section 10.8l.7).
local function on_station_vitals(event_name, param)
    if not param or type(param) ~= "string" then
        return
    end
    local idx, hull, shield, state = param:match("^(%d+),([^,]+),([^,]+),(%d+)$")
    if not idx then
        DebugError("x4mp_bridge: bad station vitals payload: " .. tostring(param))
        return
    end
    local nv = nums(param, idx, hull, shield, state) 
    if not nv then return end 
    AddUITriggeredEvent('X4MP_StationVitalsSync', 'vitals', nv)
end

-- Doc 4 section 4.6 V2: the local mirror station shot the peer hero's replica,
-- so the DLL is re-asserting the host's authoritative values for it.
-- Payload "hullPct,shieldPct" (-1 = leave unchanged).
local function on_ghost_vitals(event_name, param)
    if not param or type(param) ~= "string" then
        return
    end
    local hull, shield = param:match("^([^,]+),([^,]+)$")
    if not hull then
        DebugError("x4mp_bridge: bad ghost vitals payload: " .. tostring(param))
        return
    end
    local nv = nums(param, hull, shield) 
    if not nv then return end 
    AddUITriggeredEvent('X4MP_GhostSync', 'vit', nv)
end

RegisterEvent("x4mp_station_vitals", safe("station_vitals", on_station_vitals))
RegisterEvent("x4mp_ghost_vitals", safe("ghost_vitals", on_ghost_vitals))

-- ---------------------------------------------------------------------------
-- 2026-09-21 (run #21-J, user request "station damage is per module"): one row per
-- hit MODULE, "idx,modIdx,hull". A station's damage lives on its modules and a
-- station only dies when its modules are gone - so the old "clamp every module to
-- the worst value" behaviour is gone and this is what moves damage now.
-- The module index is the same on both peers because MD named the modules
-- "X4MP STN <idx>#<k>" (md\x4mp_stations.xml) - the same name-keys trick this project
-- already uses for stations ("X4MP STN n") and NPCs ("X4MP NPC n").
-- ---------------------------------------------------------------------------
local function on_station_module_hull(event_name, param)
    if not param or type(param) ~= "string" then
        return
    end
    local idx, m, hull = param:match("^(%d+),(%d+),(%-?[%d%.]+)$")
    if not idx then
        DebugError("x4mp_bridge: bad station module payload: " .. tostring(param))
        return
    end
    local nv = nums(param, idx, m, hull) 
    if not nv then return end 
    AddUITriggeredEvent('X4MP_StationModuleSync', 'mod', nv)
end

RegisterEvent("x4mp_station_module_hull", safe("station_module_hull", on_station_module_hull))

-- ---------------------------------------------------------------------------
-- 2026-09-21 (技术文档5 §5 · P0-1): the peer's personal actions, host side.
-- Payload "kind,keyType,id,modIdx" (four integers). The client's DLL observed its own
-- hero docking / undocking / crossing a station's 3 km radius - the host cannot see
-- any of that - and the host is the only side that can put it in front of a level.
--   kind    1 = docked, 2 = undocked, 3 = near-enter, 4 = near-exit
--   keyType 0 = none, 1 = station (id = station idx, modIdx = module k), 2 = npc lid
-- Numbers only in the table - the rule every lane in this bridge follows (10.8l.7).
-- ---------------------------------------------------------------------------
local function on_peer_event(event_name, param)
    if not param or type(param) ~= "string" then
        return
    end
    local kind, key, id, mod = param:match("^(%d+),(%d+),(%d+),(%d+)$")
    if not kind then
        DebugError("x4mp_bridge: bad peer event payload: " .. tostring(param))
        return
    end
    local nv = nums(param, kind, key, id, mod) 
    if not nv then return end 
    AddUITriggeredEvent('X4MP_PeerEventSync', 'ev', nv)
end

RegisterEvent("x4mp_peer_event", safe("peer_event", on_peer_event))

-- ===========================================================================
-- ★2026-09-28（run #26e · 合并 Stage 2）· 事件别名层（与 0.2-RC 的事件名对齐）
--
-- 为什么需要：两支同源分叉各有自己的 lane，事件名不完全相同。合并后
-- **DLL 的 raise 名 / 本 bridge 的 RegisterEvent / MD 的 event_ui_triggered 必须三方一致**，
-- 否则表现是"两端能连上、什么都不发生"（本项目最贵的坑，10.8l 那次就是这么丢的）。
-- 用**别名**而不是改名：本端 DLL 是旧构建（只发自己的名字）时，对端仍能接住语义。
--
-- 映射表：
--   x4mp_ghost_dock     (0.2-RC，载荷 = 站 idx)  -> 我们的 X4MP_PeerEventSync/ev kind=21 (docked)
--   x4mp_ghost_undock   (0.2-RC，无载荷)          -> kind=22 (undocked)
--   x4mp_respawn        (0.2-RC，无载荷)          -> **无对应**：我们的幽灵由关卡 cue 每 2 s 自愈
--                                                    重建 ⇒ 只记一行日志，不假装做了事
--   x4mp_puppet_reclaim (0.2-RC，载荷 = keep 数)  -> **无对应**：我们不下发 reclaim
--                                                    ⇒ 明确报警（宁可可见，不可静默）
-- 反向缺口（记在技术文档9，不在本文件修）：我们的 x4mp_host_time / x4mp_peer_hero /
-- x4mp_station_module_hull / x4mp_station_module_damage 在 0.2-RC 的 bridge 里没有注册
-- ⇒ 混装时这四条 lane 会静默消失，所以**合并后的包必须 DLL+bridge 一起发**。
-- ===========================================================================
local function on_alias_ghost_dock(event_name, param)
    local idx = (type(param) == "string") and tonumber(param:match("^(%d+)$")) or nil
    -- 他们的 idx 是"站序号"；我们的 peer-event 行是 (kind, sectorKey, objectId, moduleIdx)。
    -- 语义最近的位置就是 objectId，所以放在第 3 个字段（sectorKey 由 MD 侧按 player.sector 处理）。
    AddUITriggeredEvent('X4MP_PeerEventSync', 'ev', { 21, 0, idx or 0, 0 })
end

local function on_alias_ghost_undock(event_name, param)
    AddUITriggeredEvent('X4MP_PeerEventSync', 'ev', { 22, 0, 0, 0 })
end

local function on_alias_respawn(event_name, param)
    -- 我们的幽灵自愈由 MD 的 X4MP_Level_Ghost（每 2 s 复检 + macro 阶梯）负责 ⇒ 不重复实现。
    -- 但要让"收到了一个我们不认识的语义"可见。⚠️ 用 `if print then` 守卫：X4 Lua 里
    -- print 不保证存在，直接调用会在事件触发时报 nil 调用，把一个观测点变成新故障。
    local msg = "x4mp_bridge: x4mp_respawn received (0.2-RC peer) - our ghost self-heals in MD, no action"
    if print then print(msg) end
end

local function on_alias_reclaim(event_name, param)
    -- 我们不下发 reclaim（那是 0.2-RC 的"重连后裁剪名册"机制），收到就必须说清楚，
    -- 免得以为"对端裁剪成功了"。
    DebugError("x4mp_bridge: x4mp_puppet_reclaim is not implemented on this branch (payload=" ..
               tostring(param) .. ") - the 0.2-RC peer trimmed its roster; OUR list index may drift")
end

RegisterEvent("x4mp_ghost_dock", safe("alias_ghost_dock", on_alias_ghost_dock))
RegisterEvent("x4mp_ghost_undock", safe("alias_ghost_undock", on_alias_ghost_undock))
RegisterEvent("x4mp_respawn", safe("alias_respawn", on_alias_respawn))
RegisterEvent("x4mp_puppet_reclaim", safe("alias_reclaim", on_alias_reclaim))

-- ---------------------------------------------------------------------------
-- 2026-09-21 (技术文档5 §5 · P0-2): the host's authoritative clock.
-- Payload "hostTime,offset,stage": the host broadcasts its GetCurrentGameTime() every
-- 2 s and the client's DLL computes offset = host - local, so MD can time a stage on
-- (local age + global.$X4MPHostTimeOffset) instead of on a timer of its own - which
-- is what "两端各自计时会漂移" means in practice.
-- `stage` is reserved and currently 0: this SDK has no MD -> native path, so the
-- host's MD cannot push a stage number into the DLL (doc 5 section 5 lists the two
-- ways to close that).
-- ---------------------------------------------------------------------------
local function on_host_time(event_name, param)
    if not param or type(param) ~= "string" then
        return
    end
    local host, off, stage = param:match("^(%-?[%d%.]+),(%-?[%d%.]+),(%d+)$")
    if not host then
        DebugError("x4mp_bridge: bad host time payload: " .. tostring(param))
        return
    end
    local nv = nums(param, host, off, stage) 
    if not nv then return end 
    AddUITriggeredEvent('X4MP_HostTimeSync', 'clock', nv)
end

RegisterEvent("x4mp_host_time", safe("host_time", on_host_time))

-- ---------------------------------------------------------------------------
-- 2026-09-21 (run #21-Q): station MODULE damage, applied with the ENGINE's own
-- damage primitive instead of set_object_hull.
-- Payload "idx,modIdx,wantHullPct". Why the switch: 179 rows of
--   PEER DAMAGE VERIFY idx=2 module=3 uid=64654 name='X4MP STN 2#3'
--     want=99.00 moduleNow=100.00 stationNow=100.00 -> WRITE LOST
-- (right uid, right name, right target - and set_object_hull never landed on a station
-- module here). MD turns the difference against the module's current hull into absolute
-- points and calls <apply_attackstrength>, the primitive the ghost-ship lane has always
-- used (md\x4mp_testworld.xml:127).
-- ---------------------------------------------------------------------------
local function on_station_module_damage(event_name, param)
    if not param or type(param) ~= "string" then
        return
    end
    local idx, m, hull = param:match("^(%d+),(%d+),(%-?[%d%.]+)$")
    if not idx then
        DebugError("x4mp_bridge: bad station module damage payload: " .. tostring(param))
        return
    end
    local nv = nums(param, idx, m, hull) 
    if not nv then return end 
    AddUITriggeredEvent('X4MP_StationModuleDamageSync', 'dmg', nv)
end

RegisterEvent("x4mp_station_module_damage", safe("station_module_damage", on_station_module_damage))

-- ---------------------------------------------------------------------------
-- 2026-09-27 (run #23 · user report "客户端又创建了我们很久很久之前就废弃的靶机幽灵船"):
-- the macro NAME of the PEER's own ship ("x4mp_peer_hero").
-- The level's ghost replica ("X4MP Ghost") used to be built from a fixed literal
-- - the old "X4MP Target" test fighter's macro - so each side saw a junk fighter
-- where the other PLAYER should be. On the host that replica is the client's
-- avatar, and an S fighter cannot stand in the level's front line: it exploded
-- within ~9 s (user's screenshot "X4MP Ghost 被摧毁"), which is how the host lost
-- sight of the client completely.
-- Same vanilla form as the spawn row's out-of-band macro (ONE plain string as the
-- 3rd argument - see the 10.8l.7 note above): MD stores it in
-- global.$X4MPPeerHeroMacro and the level builds (or re-builds) its replica from
-- it. The DLL repeats the row once a second, so missing the first one - the level
-- module is still loading - costs one second, not the session.
-- ---------------------------------------------------------------------------
local function on_peer_hero(event_name, param)
    if not param or type(param) ~= "string" then
        return
    end
    AddUITriggeredEvent('X4MP_PeerHeroSync', 'macro', param)
end

RegisterEvent("x4mp_peer_hero", safe("peer_hero", on_peer_hero))


