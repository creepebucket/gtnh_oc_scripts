local computer = require("computer")
local comp = require("component")

-- 组件代理声明
local screen_proxy
local energy_buffer_proxy

-- 初始化组件连接
for address, name in comp.list() do
    local proxy = comp.proxy(address)
    local prefix = string.sub(address, 1, 4)
    
    if prefix == "b59c" then -- 填gpu地址
        screen_proxy = proxy
    elseif prefix == "8eb8" then -- 填蓝波顿地址
        energy_buffer_proxy = proxy
    end
end

-- 绑定显示屏
screen_proxy.bind("8ed3a0e2-8818-406a-9353-89cdb9ab4d8b", true)
screen_proxy.setDepth(4) -- 启用4位色深
local screen_width, screen_height = screen_proxy.getResolution()

-- 颜色定义（RGB值）
local COLOR_BG = 0x000000      -- 黑色背景
local COLOR_OUT = 0xFF0000    -- 红色输出
local COLOR_IN = 0x00FF00     -- 绿色输入
local COLOR_WHITE = 0xFFFFFF  -- 白色刻度和图例
local COLOR_CAP = 0xFFFF00    -- 黄色容量条

-- 功率历史数据
local history = {}
local max_history_width = screen_width - 8 -- 留出左侧刻度空间

-- 初始化屏幕
screen_proxy.setBackground(COLOR_BG)
screen_proxy.fill(1, 1, screen_width, screen_height, " ")

-- 数字格式化函数
local function formattednum(num)
    local suffixes = {"T", "G", "M", "K", ""}
    local divisors = {1e12, 1e9, 1e6, 1e3, 1}
    
    for i = 1, #suffixes do
        if math.abs(num) >= divisors[i] then
            local value = num / divisors[i]
            return value >= 100 and string.format("%.1f%s", value, suffixes[i])
                or value >= 10 and string.format("%.2f%s", value, suffixes[i])
                or string.format("%.3f%s", value, suffixes[i])
        end
    end
    return string.format("%.1f", num)
end

-- 获取能量数据
local function get_energy_data()
    local stored = energy_buffer_proxy.getEUStored()
    local max_stored = energy_buffer_proxy.getEUMaxStored()
    local sensor_info = energy_buffer_proxy.getSensorInformation()
    return {
        stored = stored,
        max_stored = max_stored,
        in_5s = tonumber(string.sub(sensor_info[10]:gsub(",", ""), 11, -17)),
        out_5s = tonumber(string.sub(sensor_info[11]:gsub(",", ""), 12, -17))
    }
end

-- 绘制Y轴刻度（优化为批量绘制）
local y_axis_cache = {}
local function draw_y_axis(max_power, y_start, height)
    screen_proxy.setForeground(COLOR_WHITE)
    
    -- 生成刻度缓存
    local new_cache = {}
    for y = y_start, y_start + height - 1 do
        local value = max_power * (1 - (y - y_start) / height)
        new_cache[y] = value >= 0 and formattednum(value)..'      ' or nil
    end
    
    -- 仅更新变化的刻度
    for y, label in pairs(new_cache) do
        if y_axis_cache[y] ~= label then
            screen_proxy.set(1, y, label)
            y_axis_cache[y] = label
        end
    end
end

-- 功率折线图绘制（优化绘制方式）
local prev_cap = {}
local function draw_power_graph(history, x_start, y_start, width, height)
    if #history == 0 then return end
    
    -- 批量清除区域
    screen_proxy.setBackground(COLOR_BG)
    screen_proxy.fill(x_start, y_start, width, height, " ")
    
    -- 计算最大功率
    local max_power = 1
    for _, data in ipairs(history) do
        max_power = math.max(max_power, data.out_power, data.in_power)
    end
    
    -- 批量绘制容量条（使用垂直填充）
    screen_proxy.setForeground(COLOR_CAP)
    local new_cap = {}
    for i = 1, width do
        if history[i] then
            local stored = history[i].stored
            local max_stored = history[i].max_stored
            if max_stored > 0 then
                local percent = stored / max_stored
                local filled_rows = math.floor(percent * height)
                new_cap[i] = filled_rows
                
                if filled_rows > 0 then
                    local x = x_start + i - 1
                    local start_y = y_start + height - filled_rows
                    -- 使用单次垂直填充代替多个set
                    screen_proxy.fill(x, start_y, 1, filled_rows, ":")
                end
            end
        end
    end
    prev_cap = new_cap
    
    -- 绘制Y轴刻度
    draw_y_axis(max_power, y_start, height)
    
    -- 新增：功率曲线绘制优化
    local function draw_curve(color, get_power, char)
        screen_proxy.setForeground(color)
        local prev_y = nil
        
        for i = #history, 1, -1 do  -- 从最旧数据开始绘制
            local x = x_start + (#history - i)  -- 计算实际X坐标
            if x > x_start + width - 1 then break end
            
            local power = get_power(history[i])
            local current_y = y_start + height - math.ceil((power / max_power) * height)
            current_y = math.min(math.max(current_y, y_start), y_start + height - 1)
            
            if prev_y then
                -- 绘制垂直线段连接当前点和前一个点
                local start_y = math.min(prev_y, current_y)
                local end_y = math.max(prev_y, current_y)
                if end_y - start_y == 0 then
                    screen_proxy.set(x, start_y, char)
                else
                    screen_proxy.fill(x, start_y, 1, end_y - start_y + 1, char)
                end
            else
                screen_proxy.set(x, current_y, char)
            end
            
            prev_y = current_y
        end
    end

    -- 绘制输入输出曲线
    draw_curve(COLOR_OUT, function(data) return data.out_power end, 'O')
    draw_curve(COLOR_IN, function(data) return data.in_power end, 'X')
end

-- 时间格式化（保持不变）
local function format_time(seconds)
    if seconds <= 0 then return "N/A" end
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = math.floor(seconds % 60)
    
    local parts = {}
    if hours > 0 then table.insert(parts, hours.."小时") end
    if minutes > 0 then table.insert(parts, minutes.."分钟") end
    if secs > 0 or #parts == 0 then table.insert(parts, secs.."秒") end
    
    return table.concat(parts, " ")
end

-- 时间计算函数（保持不变）
local function calculate_time(energy, in_power, out_power)
    local net_power = in_power - out_power
    if net_power == 0 then return "稳定", "N/A" end
    
    local remaining
    if net_power > 0 then
        remaining = (energy.max_stored - energy.stored) / (net_power * 20)
        return "充满时间", format_time(remaining)
    else
        remaining = energy.stored / (-net_power * 20)
        return "放空时间", format_time(remaining)
    end
end

-- 主循环
while true do
    screen_proxy.setForeground(COLOR_WHITE)
    screen_proxy.set(1, 1, '------------------------------------电网信息------------------------------------')
    local data = get_energy_data()
    
    -- 更新历史数据
    table.insert(history, 1, {
        in_power = data.in_5s,
        out_power = data.out_5s,
        stored = data.stored,
        max_stored = data.max_stored
    })
    if #history > max_history_width then
        table.remove(history, #history)
    end

    -- 绘制功率图表
    draw_power_graph(history, 8, 2, max_history_width, 23)
    
    -- 更新状态栏（优化为局部更新）
    local current_percent = (data.stored / data.max_stored) * 100
    local net_power = data.in_5s - data.out_5s
    local time_type, time_value = calculate_time(data, data.in_5s, data.out_5s)
    screen_proxy.setForeground(COLOR_WHITE)
    
    local new_status = string.format("O-输出 X-输入 | 当前存储: %s / %s EU(%.1f%%) | %s: %s",
        formattednum(data.stored), formattednum(data.max_stored), 
        current_percent,
        time_type, time_value)
    
    -- 仅当状态变化时更新
    if new_status ~= (screen_proxy._last_status or "") then
        screen_proxy.fill(1, 25, screen_width, 1, " ")
        screen_proxy.set(1, 25, new_status)
        screen_proxy._last_status = new_status
    end
end
