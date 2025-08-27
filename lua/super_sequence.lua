-- 万象拼音方案新成员：手动自由排序
-- 数据存放于 userdb 中，处于性能考量，此排序仅影响当前输入码
-- ctrl+j 前移
-- ctrl+k 后移
-- ctrl+l 重置
-- ctrl+p 置顶
local wanxiang = require("wanxiang")
local userdb = require("lib/userdb")

local LAST_MIGRATION_VERSION = "9.1.3"
local DEFAULT_SEQ_KEY = {
    up    = "Control+j",
    down  = "Control+k",
    reset = "Control+l",
    pin   = "Control+p",
}

local seq_db = userdb.LevelDb("lua/sequence")

local seq_property = {
    ADJUST_KEY = "sequence_adjustment_code",
}
---@param context Context
function seq_property.get(context)
    return context:get_property(seq_property.ADJUST_KEY)
end

---@param context Context
function seq_property.reset(context)
    local code = seq_property.get(context)
    if code ~= nil and code ~= "" then
        context:set_property(seq_property.ADJUST_KEY, "")
    end
end

local curr_state = {}
---@enum AdjustStateMode
curr_state.ADJUST_MODE = {
    None = -1,
    Reset = 0,
    Pin = 1,
    Adjust = 2
}
curr_state.default = {
    ---@type string | nil 当前选中的候选词，用户正常模式排序
    selected_phrase = nil,
    ---@type integer 当前选中的位置索引，用于命令模式排序
    offset = 0,
    ---@type AdjustStateMode 当前调整模式
    mode = curr_state.ADJUST_MODE.None,
    ---@type integer | nil 当前高亮索引。nil 为初始值
    highlight_index = nil,
    ---@type string | nil 当前的 adjust_code
    adjust_code = nil,
    ---@type string | integer | nil 当前的 adjust_key
    adjust_key = nil,
}
function curr_state.reset()
    -- 如果是 nil，则已经是默认值了，不行要重置
    if not curr_state.has_adjustment() then return end

    for key, value in pairs(curr_state.default) do
        curr_state[key] = value
    end
end

function curr_state.is_pin_mode()
    return curr_state.mode == curr_state.ADJUST_MODE.Pin
end

function curr_state.is_reset_mode()
    return curr_state.mode == curr_state.ADJUST_MODE.Reset
end

function curr_state.is_adjust_mode()
    return curr_state.mode == curr_state.ADJUST_MODE.Adjust
end

function curr_state.has_adjustment()
    return curr_state.mode ~= curr_state.ADJUST_MODE.None
end

---解析单个排序信息字符串
---@param value_item string
---@return string | nil, RuntimeAdjustment | nil
local function parse_adjustment_value_item(value_item)
    local item, fixed_position, offset, updated_at =
        value_item:match("i=(%S+) p=(%S+) o=(%S*) t=(%S+)") -- 兼容旧数据格式，offset 可能为 0
    fixed_position = fixed_position and tonumber(fixed_position)
    offset = offset and tonumber(offset) or 0
    updated_at = updated_at and tonumber(updated_at)
    -- 忽略为 0 的位置，0 位置代表重置
    if fixed_position and fixed_position > 0 then
        return item, {
            fixed_position = fixed_position,
            offset = offset,
            updated_at = updated_at,
        }
        -- log.warning(string.format("[sequence] %s: %s", adjust_key, value))
    end

    return nil, nil
end

---从数据库中的排序字符串中解析排序数据。
---一个输入码，对应多条排序信息，用制表符分割
---@return table<string, RuntimeAdjustment> | nil
local function parse_adjustment_values(values_str)
    local adjustments = {}

    for value in values_str:gmatch("[^\t]+") do
        local item, adjustment = parse_adjustment_value_item(value)
        if item then
            adjustments[item] = adjustment
        end
    end

    return next(adjustments) and adjustments or nil
end

---@param input string 当前输入码
---@return table<string, RuntimeAdjustment> | nil
local function get_input_adjustments(input)
    if input == "" or input == nil then return nil end

    local value_str = seq_db:fetch(input)
    if value_str == nil then return nil end

    return parse_adjustment_values(value_str)
end

-- 由于 lua os.time() 的精度只到秒，排序过快可能会引起问题
local function get_timestamp()
    return rime_api.get_time_ms
        and os.time() + tonumber(string.format("0.%s", rime_api.get_time_ms()))
        or os.time()
end

---@class Adjustment
---@field fixed_position integer `0` 为重置，>0 为目标位置
---@field offset integer 0 表示置顶／重置，<0 前移位数，>0 后移位数
---@field updated_at number 操作时间戳

---@class RuntimeAdjustment: Adjustment
---@field raw_position? integer 去重后的原始位置
---@field from_position? integer 每次应用移动后的当前位置

---@param input string 匹配的输入码
---@param item string 调整项：命令模式为候选索引，其他为候选词
---@param adjustment Adjustment
local function save_adjustment(input, item, adjustment)
    if input == "" or input == nil then
        log.warning(string.format("[sequence] 输入码不能为空: %s", input))
        return
    end

    local adjustments = get_input_adjustments(input) or {}

    adjustments[item] = {
        fixed_position = adjustment.fixed_position,
        offset = adjustment.offset,
        updated_at = adjustment.updated_at,
    }

    local values = {}
    for item, item_adjustment in pairs(adjustments) do
        local value_str = string.format("i=%s p=%s o=%s t=%s",
            item,
            item_adjustment.fixed_position,
            item_adjustment.offset,
            item_adjustment.updated_at)
        table.insert(values, value_str)
    end

    return seq_db:update(input, table.concat(values, "\t"))
end

---从 context 中获取当前排序匹配码
---@param context Context
---@return string | nil
local function extract_adjustment_code(context)
    if wanxiang.is_function_mode_active(context) then
        local code = seq_property.get(context)
        if code and code ~= "" then
            return code
        end
        return nil
    end

    return context.input:sub(1, context.caret_pos)
end

local sync_file_name = rime_api.get_user_data_dir() .. "/lua/sequence.txt"

---将旧数据转化为新数据格式
---@param key string db key
---@param value string db value
local function transform_legacy_record(key, value)
    local new_input, new_value = key, value

    local input, item = key:match("^(.+)|(.+)$")
    if input and item then
        new_input = input
        local fixed_position, offset, updated_at = value:match("([-%d]+),?([-%d]*)\t([.%d]+)")
        if not offset or offset == "" then offset = 0 end
        new_value = string.format("i=%s p=%s o=%s t=%s", item, fixed_position, offset, updated_at)
    end

    return new_input, new_value
end

local seq_data = {}
---@type "pending" | "initialing" | "done"
seq_data.status = "pending"

function seq_data.init()
    if seq_data.status ~= "pending" then return end

    seq_db:open()
    seq_data.status = "initialing"
    seq_data.db_migration()
    seq_data.import_from_file()
    seq_data.status = "done"
end

function seq_data.db_migration()
    local migration_key = "migration_version"
    local migration_version = seq_db:meta_fetch(migration_key)
    if migration_version == LAST_MIGRATION_VERSION then
        return
    end

    local migration_count = 0
    seq_db:query_with("", function(key, value)
        local new_key, new_value = transform_legacy_record(key, value)
        if key ~= new_key then
            local item, adjustment = parse_adjustment_value_item(new_value)
            if item and adjustment then
                save_adjustment(new_key, item, adjustment)
                seq_db:erase(key)
                migration_count = migration_count + 1
            end
        end
    end)

    seq_db:meta_update(migration_key, LAST_MIGRATION_VERSION)
    if migration_count > 0 then
        log.info(string.format("[sequence] 完成旧格式数据迁移，共 %s 条", migration_count))
    end
end

function seq_data.import_from_file()
    local file = io.open(sync_file_name, "r")
    if not file then return end;

    local import_count = 0

    local user_id = wanxiang.get_user_id()
    local file_user_id = nil
    for line in file:lines() do
        if line == "" then goto continue end
        -- 先找 from_user_id
        if file_user_id == nil then
            file_user_id = string.match(line, "^" .. "\001" .. "/user_id\t(.+)")
            goto continue
        end

        -- 如果 user_id 一致，则不进行同步
        if file_user_id == user_id then break end
        -- 忽略开头是 "\001/" 开头
        if line:sub(1, 2) == "\001" .. "/" then goto continue end

        -- 以下开始处理输入
        local key, value = line:match("^(%S+)\t(.+)$")

        if key and value then
            local input, value_item = transform_legacy_record(key, value)
            local item, adjustment = parse_adjustment_value_item(value_item)
            if item == nil or adjustment == nil then goto continue end

            local curr_adjustments = get_input_adjustments(input)
            if curr_adjustments
                and curr_adjustments[item]
                and adjustment.updated_at <= curr_adjustments[item].updated_at
            then
                -- 跳过旧的数据
                goto continue
            end

            import_count = import_count + 1
            save_adjustment(input, item, adjustment)
        end

        ::continue::
    end

    log.info(string.format("[sequence] 自动导入排序数据 %s 条", import_count))

    file:close()
    if import_count > 0 then
        os.remove(sync_file_name)
    end
end

-- 导出排序数据
--
-- 每行数据格式如下：
-- ```console
--   制表符分割
--       |        空格分割
--       |            |
--       v            v
--  /rq	i=2 p=1 o=0 t=1752737077.5417
--  vuvj	i=主站 p=1 o=0 t=1752737072.5412
--   ^        ^     ^   ^          ^
--   |        |     |   |          |
-- 输入码   排序项  | 偏移量     时间戳
--                  |
--                 位置
-- ```
--
-- 其中：
-- - i 排序项：普通模式为「候选词」，功能模式为「候选索引」（从 0  开始计算）
-- - p 位置：
--   - 重置为 `0`
--   - 置顶为 `1`
--   - 其他值为移动后的位置。（此种情况只做记录，实际排序按偏移量计算）
-- - o 偏移量：前／后移动的偏移量
--   - 前移 `<0`
--   - 后移 `>0`
--   - 「重置」、「置顶」等非前／后移操作为 `0`
function seq_data:export_to_file()
    -- 文件已存在不进行覆盖
    if wanxiang.file_exists(sync_file_name) then return end

    local file = io.open(sync_file_name, "w")
    if not file then return end;

    ---@type nil | DbAccessor
    seq_db:query_with("", function(key, value)
        -- 兼容旧数据
        local new_key, new_value = transform_legacy_record(key, value)

        if new_key:sub(1, 2) == "\001" .. "/" then
            local line = string.format("%s\t%s", new_key, new_value)
            local from_user_id = string.match(line, "^" .. "\001" .. "/user_id\t(.+)")
            if from_user_id ~= nil then
                local fixed_user_id = wanxiang.get_user_id()
                if fixed_user_id ~= from_user_id then
                    line = "\001" .. "/user_id\t" .. fixed_user_id
                end
            end
            file:write(line, "\n")
        else
            for adj_str in new_value:gmatch("[^\t]+") do
                local line = string.format("%s\t%s", new_key, adj_str)
                file:write(line, "\n")
            end
        end
    end)

    log.info(string.format("[sequence] 已导出排序数据至文件 %s", sync_file_name))

    file:close()
end

local P = {}
function P.init()
    seq_data.init()
end

---执行排序调整
---@param context Context
local function process_adjustment(context)
    local selected_cand = context:get_selected_candidate()
    curr_state.selected_phrase = selected_cand.text

    context:refresh_non_confirmed_composition()

    if context.highlight
        and curr_state.highlight_index
        and curr_state.highlight_index > 0 then
        context:highlight(curr_state.highlight_index)
    end
end

-- P 阶段按键处理
---@param key_event KeyEvent
---@param env Env
---@return ProcessResult
function P.func(key_event, env)
    local context = env.engine.context
    ---重置状态
    seq_property.reset(context)
    curr_state.reset()

    local selected_cand = context:get_selected_candidate()

    if not context:has_menu()
        or selected_cand == nil
        or selected_cand.text == nil
    then
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end

    -- 判断按下的键，更新偏移量
    local key_repr = key_event:repr()

    local function get_seq_key(type)
        return env.engine.schema.config:get_string("key_binder/sequence/" .. type)
            or DEFAULT_SEQ_KEY[type]
    end

    if key_repr == get_seq_key("up") then -- 前移
        curr_state.offset = -1
        curr_state.mode = curr_state.ADJUST_MODE.Adjust
    elseif key_repr == get_seq_key("down") then -- 后移
        curr_state.offset = 1
        curr_state.mode = curr_state.ADJUST_MODE.Adjust
    elseif key_repr == get_seq_key("reset") then -- 重置
        curr_state.offset = nil
        curr_state.mode = curr_state.ADJUST_MODE.Reset
    elseif key_repr == get_seq_key("pin") then -- 置顶
        curr_state.offset = nil
        curr_state.mode = curr_state.ADJUST_MODE.Pin
    else
        return wanxiang.RIME_PROCESS_RESULTS.kNoop
    end

    process_adjustment(context)

    return wanxiang.RIME_PROCESS_RESULTS.kAccepted
end

local F = {}

function F.fini()
    seq_data:export_to_file()
end

---应用之前的调整
-- 注意：此函数按时间顺序重新应用调整。
-- 在候选数量较多且单个输入代码需要进行多次调整的情况下，
-- 在循环中使用 `table.remove` 可能会成为性能瓶颈，
-- 因为它具有线性时间复杂度 (O(n))。
---@param candidates table<Candidate>
---@param prev_adjustments table
local function apply_prev_adjustment(candidates, prev_adjustments)
    -- 获取当前输入码的自定义排序项数组，并按操作时间从前到后手动排序
    local user_adjustment_list = {}
    for _, info in pairs(prev_adjustments) do
        if info.raw_position then
            info.from_position = info.raw_position -- from_position 用于动态排序
            table.insert(user_adjustment_list, info)
        end
    end
    table.sort(user_adjustment_list, function(a, b) return a.updated_at < b.updated_at end)

    -- 恢复至上次调整状态
    local candidates_size = #candidates
    local user_adjustments_count = #user_adjustment_list
    for i, record in ipairs(user_adjustment_list) do
        local from_position = record.from_position

        if from_position == nil or record.fixed_position <= 0 then
            goto continue_restore
        end

        local to_position = record.offset == 0     -- 如果 offset 为 0
            and record.fixed_position              -- 则使用固定位置
            or record.raw_position + record.offset -- 否则使用偏移量计算新位置

        -- 有时候词库变动，可能会导致偏移量超出范围，这里需要修正一下
        if to_position < 1 then
            to_position = 1
        elseif to_position > candidates_size then
            to_position = candidates_size
        end

        if from_position == to_position then
            goto continue_restore
        end

        local candidate = table.remove(candidates, from_position)
        table.insert(candidates, to_position, candidate)
        -- log.warning(string.format("[sequence] %s: %s -> %s", candidate.text, from_position, to_position))

        -- 修正后续由于移位导致的 from_position 变动
        local min_position = math.min(from_position, to_position)
        local max_position = math.max(from_position, to_position)
        for j = i, user_adjustments_count, 1 do
            local r = user_adjustment_list[j]
            if min_position <= r.from_position and r.from_position <= max_position then
                local offset = to_position < from_position and 1 or -1
                user_adjustment_list[j].from_position = r.from_position + offset
            end
        end
        ::continue_restore::
    end
end

local function apply_curr_adjustment(candidates, curr_adjustment)
    if curr_adjustment == nil then return end

    ---@type integer | nil
    local from_position = nil
    for position, cand in ipairs(candidates) do
        if cand.text == curr_state.selected_phrase then
            from_position = position
            break
        end
    end

    if from_position == nil then return end

    local to_position = from_position
    if curr_state.is_adjust_mode() then
        to_position = from_position + curr_state.offset
        curr_adjustment.offset = to_position - curr_adjustment.raw_position
        curr_adjustment.fixed_position = to_position

        local min_position, max_position = 1, #candidates
        if from_position ~= to_position then
            if to_position < min_position then
                to_position = min_position
            elseif to_position > max_position then
                to_position = max_position
            end

            local candidate = table.remove(candidates, from_position)
            table.insert(candidates, to_position, candidate)

            save_adjustment(curr_state.adjust_code, curr_state.adjust_key, curr_adjustment)
        end
    end

    curr_state.highlight_index = to_position - 1
end

---当前 context 是否允许自定义排序
---@param context Context
---@return boolean
local function is_adjustment_allowed(context)
    if wanxiang.is_function_mode_active(context) -- function mode 必须有设置 sequence_adjustment_code
        and seq_property.get(context) == nil then
        return false
    end

    return true
end

---@param input Translation
---@param env Env
function F.func(input, env)
    local function original_list()
        for cand in input:iter() do yield(cand) end
    end

    local context = env.engine.context

    local adjustment_allowed = is_adjustment_allowed(context)
    if not adjustment_allowed then
        log.warning(string.format("[sequence] 暂不支持当前指令的手动排序"))
        return original_list()
    end

    local adjust_code = extract_adjustment_code(context)
    if adjust_code == nil then
        return original_list()
    end

    local prev_adjustments = get_input_adjustments(adjust_code)

    ---@type RuntimeAdjustment | nil
    local curr_adjustment = nil
    if curr_state.has_adjustment() then
        curr_adjustment = {
            fixed_position = 0,
            offset = 0,
            updated_at = get_timestamp(),
        }
    end

    if curr_adjustment == nil       -- 如果当前没有排序调整
        and prev_adjustments == nil -- 并且之前也没有自定义排序
    then                            -- 直接 yield 并返回
        return original_list()
    end

    --- 原始候选去重，并获取原始位置信息和 adjust_key & adjust_code
    ---@type table<Candidate>
    local candidates = {}  -- 去重排序后的候选列表
    local hash_phrase = {} -- 用于去重
    local is_function_mode_active = wanxiang.is_function_mode_active(context)
    local position = 0
    for candidate in input:iter() do
        local phrase = candidate.text
        if not hash_phrase[phrase] then
            hash_phrase[phrase] = true

            -- 依次插入得到去重后的列表
            position = position + 1
            table.insert(candidates, candidate)

            local curr_key = is_function_mode_active
                and tostring(position - 1) -- function mode 使用索引模式
                or phrase

            if curr_adjustment ~= nil and curr_state.selected_phrase == phrase then
                curr_state.adjust_code = adjust_code
                curr_state.adjust_key = curr_key

                curr_adjustment.raw_position = position
            end

            if prev_adjustments and prev_adjustments[curr_key] ~= nil then
                prev_adjustments[curr_key].raw_position = position -- raw_position 记录原始顺序
            end
        end
    end

    prev_adjustments = prev_adjustments or {}

    -- 提前处理置顶/重置操作，以简化逻辑
    if curr_adjustment ~= nil and not curr_state.is_adjust_mode() then
        curr_adjustment.offset = 0

        local key = tostring(curr_state.adjust_key)
        if curr_state.is_reset_mode() then -- reset mode 提前清空之前的旧数据
            curr_adjustment.fixed_position = 0
            prev_adjustments[key] = nil
        elseif curr_state.is_pin_mode() then
            curr_adjustment.fixed_position = 1
            prev_adjustments[key] = curr_adjustment
        end

        save_adjustment(curr_state.adjust_code, curr_state.adjust_key, curr_adjustment)
    end

    apply_prev_adjustment(candidates, prev_adjustments)

    apply_curr_adjustment(candidates, curr_adjustment)

    -- 输出最终结果
    for _, cand in ipairs(candidates) do
        yield(cand)
    end
end

return { P = P, F = F }
