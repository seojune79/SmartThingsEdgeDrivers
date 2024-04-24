local log = require "log"
local capabilities = require "st.capabilities"
local json = require "st.json"

local mzp = {}

mzp.capability = capabilities["multipleZonePresence"]
mzp.id = "multipleZonePresence"
mzp.zoneInfoTable = {}
mzp.commands = {}
mzp.maxZoneId = -1

mzp.present = "present"
mzp.notPresent = "not present"

function mzp.findZoneById(id)
    for index, zoneInfo in pairs(mzp.zoneInfoTable) do
       if zoneInfo.id == id then
         return zoneInfo, index
       end
    end
    return nil, nil
end

function mzp.findNewZoneId()
    local maxId = mzp.maxZoneId
    for _, zoneInfo in pairs(mzp.zoneInfoTable) do
        local intId = tonumber(zoneInfo.id)
        if intId and intId > maxId then
            maxId = intId
        end
    end
    return tostring(maxId + 1)
end

function mzp.createZone(name, id)
    local err, createdId = nil, nil
    local zoneInfo = {}
    if id == nil then
        id = mzp.findNewZoneId()
    end
    if mzp.findZoneById(id) then
        err = string.format("id %s already exists", id)
        mzp.maxZoneId = mzp.maxZoneId + 1
        return err, createdId
    end
    zoneInfo.id = id
    zoneInfo.name = name
    zoneInfo.state = mzp.notPresent
    table.insert(mzp.zoneInfoTable, zoneInfo)
    createdId = id

    local intId = tonumber(id)
    if intId and intId > mzp.maxZoneId then
        mzp.maxZoneId = intId
    end

    return err, createdId
end

function mzp.deleteZone(id)
    local err, deletedId = nil, nil
    local zoneInfo, index = mzp.findZoneById(id)
    if zoneInfo then
        table.remove(mzp.zoneInfoTable, index)
        deletedId = id
    else
        err = string.format("id %s doesn't exists", id)
    end
    return err, deletedId
end

function mzp.renameZone(id, name)
    print("----- [renameZone] entry")
    local err, changedId = nil, nil
    local zoneInfo = mzp.findZoneById(id)
    if zoneInfo then
        print("----- [renameZone] zoneInfo change, name = "..name.." / id = "..id)
        zoneInfo.name = name
        changedId = id
    else
        err = string.format("id %s doesn't exists", id)
    end
    print("----- [renameZone] exit")
    return err, changedId
end

function mzp.changeState(id, state)
    local err, changedId = nil, nil
    local zoneInfo = mzp.findZoneById(id)
    if zoneInfo then
        zoneInfo.state = state
        changedId = id
    else
        err = string.format("id %s doesn't exists", id)
    end
    return err, changedId
end

mzp.commands.updateZoneName = {}
mzp.commands.updateZoneName.name = "updateZoneName"
function mzp.commands.updateZoneName.handler(driver, device, args)
    print("-----[updateZoneName.handler] entry")
    log.error("UPDATE_ZONE_NAME")
    local name = args.args.name
    local id = args.args.id
    print("-----[updateZoneName.handler] name = "..tostring(name).." / id = "..tostring(id))
    log.error("NAME::: " .. tostring(name))
    log.error("ID::: " .. tostring(id))
    mzp.renameZone(id, name)
    mzp.updateAttribute(driver, device)
    print("-----[updateZoneName.handler] exit")
end

mzp.commands.deleteZone = {}
mzp.commands.deleteZone.name = "deleteZone"
function mzp.commands.deleteZone.handler(driver, device, args)
    local id = args.args.id
    mzp.deleteZone(id)
    mzp.updateAttribute(driver, device)
end

mzp.commands.createZone = {}
mzp.commands.createZone.name = "createZone"
function mzp.commands.createZone.handler(driver, device, args)
    local name = args.args.name
    local id = args.args.id
    mzp.createZone(name, id)
    mzp.updateAttribute(driver, device)
end

function mzp.updateAttribute(driver, device)
    device:emit_event(mzp.capability.zoneState({value = mzp.zoneInfoTable}, {data = { lastId = "MYID", state = "present"}}))
end

return mzp
