local ssub  = string.sub
local sgsub = string.gsub
local sfmt  = string.format

local gnamestrCache = {}

local ignore = {
}

local ignorePatt = {
}

local rqirtemplateCache = { }
local function rqirtemplate(uri)
    local result = rqirtemplateCache[uri]
    if not result then
        result                 = { }
        rqirtemplateCache[uri] = result

        local config     = require 'config'
        local searchers  = config.get(uri, 'Lua.runtime.path')

        for i = 1, #searchers do
            result[i] = uri .. '/' .. ssub(searchers[i], 1, #searchers[i] - 5)
        end
    end

    return result
end


local require2UriCache = { }
local function require2Uri(uri, requirename)
    if not require2UriCache[uri] then
        require2UriCache[uri] = { }
    end

    local cache = require2UriCache[uri][requirename]
    if cache == false then
        return nil
    end

    if cache then
        return cache
    end

    local fs        = require 'bee.filesystem'
    local furi      = require 'file-uri'
    local templates = rqirtemplate(uri)
    if templates then
        for i = 1, #templates do
            local candidate   = sfmt("%s%s%s", templates[i], sgsub(requirename, '%.', '/'), ".lua")
            local path        = fs.path(furi.decode(candidate))
            local suc, exists = pcall(fs.exists, path)
            if suc and exists then
                candidate = ssub(candidate, #uri + 2, #candidate - 4)
                candidate = 'FENV__' .. sgsub(candidate, '[^%a%d_]+', '_')
                require2UriCache[uri][requirename] = candidate
                return candidate
            end
        end
    end

    require2UriCache[uri][requirename] = false
    return nil
end

local function findUrisByRequireName(scp, requireName)
    if ignore[requireName] then
        return false
    end

    for i = 1, #ignorePatt do
        local p = ignorePatt[i]
        if ssub(requireName, p[2], p[3]) == p[1] then
            return false
        end
    end

    return require2Uri(scp.uri, requireName)
end

return function (state)
    local env = state.ast.locals[1]
    if state.ast.type ~= 'main' then
        return
    end

    local scope      = require 'workspace.scope'
    local scp        = scope.getScope(state.uri)
    -- local 变量初始化时就绑定到 require 的返回值，此后没有 setlocal 且有 getlocal
    -- 所有对这个变量的 getlocal 转化为 getGlobal
    local allrequires = state.specials and state.specials['require']
    if not allrequires or #allrequires <= 0 then
        goto REQUIRE_PROC_END
    end

    for i = 1, #allrequires do
        local rqir = allrequires[i]
        local callrqir = rqir.parent
        if not callrqir or callrqir.type ~= 'call' then
            goto CONTINUE
        end
        local selectrtn = callrqir.parent
        if not selectrtn or selectrtn.type ~= 'select' then
            goto CONTINUE
        end
        local loc = selectrtn.parent
        if not loc or loc.special or loc.type ~= 'local' or loc.tag ~= 'localreqiresetonec' then
            goto CONTINUE
        end
        if not loc.ref then
            goto CONTINUE
        end
        local nameArg = callrqir.args[1]
        if not nameArg or nameArg.type ~= 'string' then
            goto CONTINUE
        end
        local rqirname = nameArg[1]
        if not rqirname or type(rqirname) ~= 'string' then
            goto CONTINUE
        end

        local gnamestr
        if state.options.fenvasglobal then
            gnamestr = findUrisByRequireName(scp, rqirname)
        end
        if not gnamestr then
            goto CONTINUE
        end
        for j = #loc.ref, 1, -1 do
            local getloc = loc.ref[j]
            loc.ref[j] = nil
            getloc[1] = gnamestr

            getloc.type = 'getglobal'
            getloc.node = env
            if not env.ref then
                env.ref = {}
            end
            env.ref[#env.ref+1] = getloc
        end

        ::CONTINUE::
    end
    ::REQUIRE_PROC_END::

    -- 找到所有全局变量赋值操作, 这些操作应该被视作创建文件域变量
    -- 将所有文件域变量同名的 get/set global 转化为对 FENV__u_r_i 的 get/set field
    local fenvsymbols = { }
    if not env.ref or not state.options.fenvasglobal then
        goto GETSET_GLOBAL_END
    end

    for i = 1, #env.ref do
        local node = env.ref[i]
        if not (node.special or node.tag == '__FENVASGLOBAL') and node.type == "setglobal" then
            fenvsymbols[node[1]] = true
        end
    end

    for i = 1, #env.ref do
        local node = env.ref[i]
        if node.special or node.tag == '__FENVASGLOBAL' or not fenvsymbols[node[1]] then
            goto CONTINUE
        end

        if node.type == 'getglobal' then
            node.type = 'getfield'
        elseif node.type == 'setglobal' then
            node.type = 'setfield'
        else
            goto CONTINUE
        end

        node.node = {
            type   = 'getglobal',
            start  = node.start,
            finish = node.start - 1,
            node   = env,
            parent = node,
            next   = node,
            [1]    = state.rtnfenv[1],
        }
        env.ref[i] = node.node

        node.field = {
            type = 'field',
            start = node.start,
            finish = node.finish,
            parent = node,
            [1] = node[1]
        }
        node[1] = nil

        ::CONTINUE::
    end
    ::GETSET_GLOBAL_END::
end
