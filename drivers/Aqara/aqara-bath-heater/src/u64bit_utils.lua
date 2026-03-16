local u64bit_utils = {}

local function mask_nbits(n)
    assert(n >= 1 and n <= 64, "n must be in 1..64")
    if n == 64 then
        return 0xFFFFFFFFFFFFFFFF
    end
    return (1 << n) - 1
end

function u64bit_utils.get_bit(value, bitpos)
    assert(bitpos >= 0 and bitpos <= 63, "bitpos must be in 0..63")
    return (value >> bitpos) & 1
end

function u64bit_utils.set_bit(value, bitpos, bit)
    assert(bitpos >= 0 and bitpos <= 63, "bitpos must be in 0..63")
    assert(bit == 0 or bit == 1, "bit must be 0 or 1")

    local clear_mask = ~(1 << bitpos)
    value = value & clear_mask
    value = value | (bit << bitpos)
    return value
end

function u64bit_utils.get_bits(value, start_bit, width)
    assert(start_bit >= 0 and start_bit <= 63, "start_bit must be in 0..63")
    assert(width >= 1 and width <= 64, "width must be in 1..64")
    assert(start_bit + width <= 64, "bit range out of bounds")

    local mask = mask_nbits(width)
    return (value >> start_bit) & mask
end

function u64bit_utils.set_bits(value, start_bit, width, field_value)
    assert(start_bit >= 0 and start_bit <= 63, "start_bit must be in 0..63")
    assert(width >= 1 and width <= 64, "width must be in 1..64")
    assert(start_bit + width <= 64, "bit range out of bounds")

    local mask = mask_nbits(width)
    assert((field_value & ~mask) == 0, "field_value does not fit in width bits")

    local shifted_mask = mask << start_bit
    value = value & ~shifted_mask
    value = value | ((field_value & mask) << start_bit)
    return value
end

-- 64비트 2진수 문자열로 변환
function u64bit_utils.to_binary(value)
    local t = {}
    for i = 63, 0, -1 do
        t[#t + 1] = ((value >> i) & 1) == 1 and "1" or "0"
    end
    return table.concat(t)
end

-- 보기 좋게 8비트씩 _ 구분
function u64bit_utils.to_binary_grouped(value)
    local t = {}
    for i = 63, 0, -1 do
        t[#t + 1] = ((value >> i) & 1) == 1 and "1" or "0"
        if i % 8 == 0 and i ~= 0 then
            t[#t + 1] = "_"
        end
    end
    return table.concat(t)
end

return u64bit_utils