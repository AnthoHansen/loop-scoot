ScootUiFocus = {}
local current, serial, stopping, externalCheck = nil, 0, false, nil
function ScootUiFocus.SetExternalCheck(check) externalCheck=check end
function ScootUiFocus.ExternalBlocked()
    if not externalCheck then return false end
    local ok,blocked=pcall(externalCheck)
    return not ok or blocked==true
end
function ScootUiFocus.Owns(lease) return lease~=nil and current==lease and not stopping end
function ScootUiFocus.Blocked(lease)
    if stopping or (current and current~=lease) or ScootUiFocus.ExternalBlocked() then return true end
    return IsNuiFocused() and not (current==lease and lease and lease.focused)
end
function ScootUiFocus.Acquire(owner)
    if owner~='phone' and owner~='collection' then return nil end
    if current or ScootUiFocus.Blocked() then return nil end
    serial=serial+1;current={owner=owner,id=serial,focused=false};return current
end
function ScootUiFocus.Activate(lease)
    if not ScootUiFocus.Owns(lease) or ScootUiFocus.Blocked(lease) then return false end
    SetNuiFocus(true,true);lease.focused=true;return true
end
function ScootUiFocus.Release(lease)
    if not lease or current~=lease then return false end
    current=nil
    if lease.focused then
        SetNuiFocus(false,false)
        if SetNuiFocusKeepInput then SetNuiFocusKeepInput(false) end
    end
    lease.focused=false;return true
end
AddEventHandler('onResourceStop',function(resource)
    if resource~=GetCurrentResourceName() then return end
    ScootUiFocus.Release(current);stopping=true
end)
