--[[
LPEGLJ
lpcap.lua
Capture functions
Copyright (C) 2014 Rostislav Sacek.
based on LPeg v0.12 - PEG pattern matching for Lua
Lua.org & PUC-Rio  written by Roberto Ierusalimschy
http://www.inf.puc-rio.br/~roberto/lpeg/

** Permission is hereby granted, free of charge, to any person obtaining
** a copy of this software and associated documentation files (the
** "Software"), to deal in the Software without restriction, including
** without limitation the rights to use, copy, modify, merge, publish,
** distribute, sublicense, and/or sell copies of the Software, and to
** permit persons to whom the Software is furnished to do so, subject to
** the following conditions:
**
** The above copyright notice and this permission notice shall be
** included in all copies or substantial portions of the Software.
**
** THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
** EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
** MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
** IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
** CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
** TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
** SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
**
** [ MIT license: http://www.opensource.org/licenses/mit-license.php ]
--]]

local Cclose = 0
local Cposition = 1
local Cconst = 2
local Cbackref = 3
local Carg = 4
local Csimple = 5
local Ctable = 6
local Cfunction = 7
local Cquery = 8
local Cstring = 9
local Cnum = 10
local Csubst = 11
local Cfold = 12
local Cruntime = 13
local Cgroup = 14

local MAXSTRCAPS = 10

local pushcapture
local addonestring


-- Goes back in a list of captures looking for an open capture
-- corresponding to a close

local function findopen(cs, index)
    local n = 0; -- number of closes waiting an open
    while true do
        index = index - 1
        if cs.ocap[index].kind == Cclose then
            n = n + 1 -- one more open to skip
        elseif cs.ocap[index].siz == 0 then
            if n == 0 then
                return index
            end
            n = n - 1
        end
    end
end


local function checknextcap(cs,  captop)
    local cap = cs.cap;
    if cs.ocap[cap].siz == 0 then -- not a single capture?    ((cap)->siz != 0)
        local n = 0; -- number of opens waiting a close
        while true do -- look for corresponding close
            cap = cap + 1
            if cap > captop then return end
            if cs.ocap[cap].kind == Cclose then
                n = n - 1
                if n + 1 == 0 then
                    break;
                end
            elseif cs.ocap[cap].siz == 0 then
                n = n + 1
            end
        end
    end
    cap = cap + 1; -- + 1 to skip last close (or entire single capture)
    if cap > captop then return end
    return true
end


-- Go to the next capture

local function nextcap(cs)
    local cap = cs.cap;
    if cs.ocap[cap].siz == 0 then -- not a single capture?    ((cap)->siz != 0)
        local n = 0; -- number of opens waiting a close
        while true do -- look for corresponding close
            cap = cap + 1
            if cs.ocap[cap].kind == Cclose then
                n = n - 1
                if n + 1 == 0 then
                    break;
                end
            elseif cs.ocap[cap].siz == 0 then
                n = n + 1
            end
        end
    end
    cs.cap = cap + 1; -- + 1 to skip last close (or entire single capture)
end


-- Push on the Lua stack all values generated by nested captures inside
-- the current capture. Returns number of values pushed. 'addextra'
-- makes it push the entire match after all captured values. The
-- entire match is pushed also if there are no other nested values,
-- so the function never returns zero.

local function pushnestedvalues(cs, addextra, out, valuetable)
    local co = cs.cap
    cs.cap = cs.cap + 1
    if cs.ocap[cs.cap - 1].siz ~= 0 then -- no nested captures?
        local st = cs.ocap[co].s
        local l = cs.ocap[co].siz - 1
        out.outindex = out.outindex + 1
        out.out[out.outindex] = cs.s and cs.s:sub(st, st + l - 1) or cs.stream(st, st + l - 1)
        return 1; -- that is it
    else
        local n = 0;
        while cs.ocap[cs.cap].kind ~= Cclose do -- repeat for all nested patterns
            n = n + pushcapture(cs, out, valuetable);
        end
        if addextra or n == 0 then -- need extra?
            local st = cs.ocap[co].s
            local l = cs.ocap[cs.cap].s - cs.ocap[co].s
            out.outindex = out.outindex + 1
            out.out[out.outindex] = cs.s and cs.s:sub(st, st + l - 1) or cs.stream(st, st + l - 1)
            n = n + 1
        end
        cs.cap = cs.cap + 1 -- skip close entry
        return n;
    end
end


-- Push only the first value generated by nested captures

local function pushonenestedvalue(cs, out, valuetable)
    local n = pushnestedvalues(cs, false, out, valuetable)
    for i = n, 2, -1 do
        out.out[out.outindex] = nil
        out.outindex = out.outindex - 1
    end
end


-- Try to find a named group capture with the name given at the top of
-- the stack; goes backward from 'cap'.

local function findback(cs, cap, name, valuetable)
    while cap > 0 do -- repeat until end of list
        cap = cap - 1
        local continue
        if cs.ocap[cap].kind == Cclose then
            cap = findopen(cs, cap); -- skip nested captures
        elseif cs.ocap[cap].siz == 0 then
            continue = true -- opening an enclosing capture: skip and get previous
        end
        if not continue and cs.ocap[cap].kind == Cgroup then
            local gname = valuetable[cs.ocap[cap].idx] -- get group name
            if name == gname then -- right group?
                return cap;
            end
        end
    end
    error(("back reference '%s' not found"):format(name), 0)
end


-- Back-reference capture. Return number of values pushed.

local function backrefcap(cs, out, valuetable)
    local curr = cs.cap;
    local name = valuetable[cs.ocap[cs.cap].idx] -- reference name
    cs.cap = findback(cs, curr, name, valuetable) -- find corresponding group
    local n = pushnestedvalues(cs, false, out, valuetable); -- push group's values
    cs.cap = curr + 1;
    return n;
end


-- Table capture: creates a new table and populates it with nested
-- captures.

local function tablecap(cs, out, valuetable)
    local n = 0;
    local t = {}
    cs.cap = cs.cap + 1
    if cs.ocap[cs.cap - 1].siz == 0 then -- table is empty
        while cs.ocap[cs.cap].kind ~= Cclose do
            local subout = { outindex = 0, out = {} }
            if cs.ocap[cs.cap].kind == Cgroup and valuetable[cs.ocap[cs.cap].idx] ~= 0 then -- named group?
                local groupname = valuetable[cs.ocap[cs.cap].idx] -- push group name
                pushonenestedvalue(cs, subout, valuetable)
                t[groupname] = subout.out[1]
            else -- not a named group
                local k = pushcapture(cs, subout, valuetable);
                for i = 1, subout.outindex do -- store all values into table
                    t[i + n] = subout.out[i]
                end
                n = n + k;
            end
        end
        cs.cap = cs.cap + 1 -- skip close entry
    end
    out.outindex = out.outindex + 1
    out.out[out.outindex] = t
    return 1; -- number of values pushed (only the table)
end


-- Table-query capture

local function querycap(cs, out, valuetable)
    local table = valuetable[cs.ocap[cs.cap].idx]
    local subout = { outindex = 0, out = {} }
    pushonenestedvalue(cs, subout, valuetable) -- get nested capture
    if table[subout.out[1]] ~= nil then -- query cap. value at table
        out.outindex = out.outindex + 1
        out.out[out.outindex] = table[subout.out[1]]
        return 1
    end
    return 0
end


-- Fold capture

local function foldcap(cs, out, valuetable)
    local fce = valuetable[cs.ocap[cs.cap].idx]
    cs.cap = cs.cap + 1
    if cs.ocap[cs.cap - 1].siz ~= 0 or -- no nested captures?
            cs.ocap[cs.cap].kind == Cclose then -- no nested captures (large subject)?
        error("no initial value for fold capture", 0);
    end
    local subout = { outindex = 0; out = {} }
    local n = pushcapture(cs, subout, valuetable) -- nested captures with no values?
    if n == 0 then
        error("no initial value for fold capture", 0);
    end
    local acumulator = subout.out[1] -- leave only one result for accumulator
    while cs.ocap[cs.cap].kind ~= Cclose do
        local subout = { outindex = 0; out = {} }
        n = pushcapture(cs, subout, valuetable); -- get next capture's values
        acumulator = fce(acumulator, unpack(subout.out, 1, subout.outindex)) -- call folding function
    end
    cs.cap = cs.cap + 1; -- skip close entry
    out.outindex = out.outindex + 1
    out.out[out.outindex] = acumulator
    return 1; -- only accumulator left on the stack
end


local function retcount(...)
    return select('#', ...), { ... }
end


-- Function capture

local function functioncap(cs, out, valuetable)
    local fce = valuetable[cs.ocap[cs.cap].idx] --  push function
    local subout = { outindex = 0, out = {} }
    local n = pushnestedvalues(cs, false, subout, valuetable); -- push nested captures
    local count, ret = retcount(fce(unpack(subout.out, 1, n))) -- call function
    for i = 1, count do
        out.outindex = out.outindex + 1
        out.out[out.outindex] = ret[i]
    end
    return count
end


-- Select capture

local function numcap(cs, out, valuetable)
    local idx = valuetable[cs.ocap[cs.cap].idx] -- value to select
    if idx == 0 then -- no values?
        nextcap(cs); -- skip entire capture
        return 0; -- no value produced
    else
        local subout = { outindex = 0, out = {} }
        local n = pushnestedvalues(cs, false, subout, valuetable)
        if n < idx then -- invalid index?
            error(("no capture '%d'"):format(idx), 0)
        else
            out.outindex = out.outindex + 1
            out.out[out.outindex] = subout.out[idx] -- get selected capture
            return 1;
        end
    end
end


-- Calls a runtime capture. Returns number of captures removed by
-- the call, including the initial Cgroup. (Captures to be added are
-- on the Lua stack.)

local function runtimecap(cs, close, s, out, valuetable)
    local open = findopen(cs, close)
    assert(cs.ocap[open].kind == Cgroup)
    cs.ocap[close].kind = Cclose; -- closes the group
    cs.ocap[close].s = s;
    cs.cap = open;
    local fce = valuetable[cs.ocap[cs.cap].idx] -- push function to be called
    local subout = { outindex = 0, out = {} }
    local n = pushnestedvalues(cs, false, subout, valuetable); -- push nested captures
    local count, ret = retcount(fce(cs.s or cs.stream, s, unpack(subout.out, 1, n))) -- call dynamic function
    for i = 1, count do
        out.outindex = out.outindex + 1
        out.out[out.outindex] = ret[i]
    end
    return close - open -- number of captures of all kinds removed
end

-- Collect values from current capture into array 'cps'. Current
-- capture must be Cstring (first call) or Csimple (recursive calls).
-- (In first call, fills %0 with whole match for Cstring.)
-- Returns number of elements in the array that were filled.

local function getstrcaps(cs, cps, n)
    local k = n
    n = n + 1
    cps[k + 1].isstring = true; -- get string value
    cps[k + 1].startstr = cs.ocap[cs.cap].s; -- starts here
    cs.cap = cs.cap + 1
    if cs.ocap[cs.cap - 1].siz == 0 then -- nested captures?
        while cs.ocap[cs.cap].kind ~= Cclose do -- traverse them
            if n >= MAXSTRCAPS then -- too many captures?
                nextcap(cs); -- skip extra captures (will not need them)
            elseif cs.ocap[cs.cap].kind == Csimple then -- string?
                n = getstrcaps(cs, cps, n); -- put info. into array
            else
                cps[n + 1].isstring = false; -- not a string
                cps[n + 1].origcap = cs.cap; -- keep original capture
                nextcap(cs);
                n = n + 1;
            end
        end
        cs.cap = cs.cap + 1 -- skip close
    end
    cps[k + 1].endstr = cs.ocap[cs.cap - 1].s + cs.ocap[cs.cap - 1].siz - 1 -- ends here
    return n;
end


-- add next capture value (which should be a string) to buffer 'b'

-- String capture: add result to buffer 'b' (instead of pushing
-- it into the stack)

local function stringcap(cs, b, valuetable)
    local cps = {}
    for i = 1, MAXSTRCAPS do
        cps[#cps + 1] = {}
    end
    local fmt = valuetable[cs.ocap[cs.cap].idx]
    local n = getstrcaps(cs, cps, 0) - 1; -- collect nested captures
    local i = 1

    while i <= #fmt do -- traverse them
        local c = fmt:sub(i, i)
        if c ~= '%' then -- not an escape?
            b[#b + 1] = c -- add it to buffer
        elseif fmt:sub(i + 1, i + 1) < '0' or fmt:sub(i + 1, i + 1) > '9' then -- not followed by a digit?
            i = i + 1
            b[#b + 1] = fmt:sub(i, i)
        else
            i = i + 1
            local l = fmt:sub(i, i) - '0'; -- capture index
            if l > n then
                error(("invalid capture index (%d)"):format(l), 0)
            elseif cps[l + 1].isstring then
                b[#b + 1] = cs.s and cs.s:sub(cps[l + 1].startstr, cps[l + 1].endstr - cps[l + 1].startstr + cps[l + 1].startstr - 1) or
                        cs.stream(cps[l + 1].startstr, cps[l + 1].endstr - cps[l + 1].startstr + cps[l + 1].startstr - 1)
            else
                local curr = cs.cap;
                cs.cap = cps[l + 1].origcap; -- go back to evaluate that nested capture
                if not addonestring(cs, b, "capture", valuetable) then
                    error(("no values in capture index %d"):format(l), 0)
                end
                cs.cap = curr; -- continue from where it stopped
            end
        end
        i = i + 1
    end
end


-- Substitution capture: add result to buffer 'b'

local function substcap(cs, b, valuetable)
    local curr = cs.ocap[cs.cap].s;
    if cs.ocap[cs.cap].siz ~= 0 then -- no nested captures?
        b[#b + 1] = cs.s and cs.s:sub(curr, cs.ocap[cs.cap].siz - 1 + curr - 1) or
                cs.stream(curr, cs.ocap[cs.cap].siz - 1 + curr - 1) -- keep original text
    else
        cs.cap = cs.cap + 1 -- skip open entry
        while cs.ocap[cs.cap].kind ~= Cclose do -- traverse nested captures
            local next = cs.ocap[cs.cap].s;
            b[#b + 1] = cs.s and cs.s:sub(curr, next - curr + curr - 1) or
                    cs.stream(curr, next - curr + curr - 1) -- add text up to capture
            if addonestring(cs, b, "replacement", valuetable) then
                curr = cs.ocap[cs.cap - 1].s + cs.ocap[cs.cap - 1].siz - 1; -- continue after match
            else -- no capture value
                curr = next; -- keep original text in final result
            end
        end
        b[#b + 1] = cs.s and cs.s:sub(curr, curr + cs.ocap[cs.cap].s - curr - 1) or
                cs.stream(curr, curr + cs.ocap[cs.cap].s - curr - 1) -- add last piece of text
    end
    cs.cap = cs.cap + 1 -- go to next capture
end


-- Evaluates a capture and adds its first value to buffer 'b'; returns
-- whether there was a value

function addonestring(cs, b, what, valuetable)
    local tag = cs.ocap[cs.cap].kind
    if tag == Cstring then
        stringcap(cs, b, valuetable); -- add capture directly to buffer
        return 1
    elseif tag == Csubst then
        substcap(cs, b, valuetable); -- add capture directly to buffer
        return 1
    else
        local subout = { outindex = 0, out = {} }
        local n = pushcapture(cs, subout, valuetable);
        if n > 0 then
            if type(subout.out[1]) ~= 'string' and type(subout.out[1]) ~= 'number' then
                error(("invalid %s value (a %s)"):format(what, type(subout.out[1])), 0)
            end
            b[#b + 1] = subout.out[1]
            return n
        end
    end
end


-- Push all values of the current capture into the stack; returns
-- number of values pushed

function pushcapture(cs, out, valuetable)
    local type = cs.ocap[cs.cap].kind
    if type == Cposition then
        out.outindex = out.outindex + 1
        out.out[out.outindex] = cs.ocap[cs.cap].s
        cs.cap = cs.cap + 1;
        return 1;
    elseif type == Cconst then
        out.outindex = out.outindex + 1
        out.out[out.outindex] = valuetable[cs.ocap[cs.cap].idx]
        cs.cap = cs.cap + 1
        return 1;
    elseif type == Carg then
        local arg = valuetable[cs.ocap[cs.cap].idx]
        cs.cap = cs.cap + 1
        if arg > cs.ptopcount then
            error(("reference to absent argument #%d"):format(arg), 0)
        end
        out.outindex = out.outindex + 1
        out.out[out.outindex] = cs.ptop[arg]
        return 1;
    elseif type == Csimple then
        local k = pushnestedvalues(cs, true, out, valuetable)
        local index = out.outindex
        table.insert(out.out, index - k + 1, out.out[index])
        out[index + 1] = nil
        return k;
    elseif type == Cruntime then
        out.outindex = out.outindex + 1
        out.out[out.outindex] = valuetable[cs.ocap[cs.cap].idx]
        cs.cap = cs.cap + 1;
        return 1;
    elseif type == Cstring then
        local b = {}
        stringcap(cs, b, valuetable)
        out.outindex = out.outindex + 1
        out.out[out.outindex] = table.concat(b)
        return 1;
    elseif type == Csubst then
        local b = {}
        substcap(cs, b, valuetable);
        out.outindex = out.outindex + 1
        out.out[out.outindex] = table.concat(b)
        return 1;
    elseif type == Cgroup then
        if valuetable[cs.ocap[cs.cap].idx] == 0 then -- anonymous group?
            return pushnestedvalues(cs, false, out, valuetable); -- add all nested values
        else -- named group: add no values
            nextcap(cs); -- skip capture
            return 0
        end
    elseif type == Cbackref then
        return backrefcap(cs, out, valuetable)
    elseif type == Ctable then
        return tablecap(cs, out, valuetable)
    elseif type == Cfunction then
        return functioncap(cs, out, valuetable)
    elseif type == Cnum then
        return numcap(cs, out, valuetable)
    elseif type == Cquery then
        return querycap(cs, out, valuetable)
    elseif type == Cfold then
        return foldcap(cs, out, valuetable)
    else
        assert(false)
    end
end


-- Prepare a CapState structure and traverse the entire list of
-- captures in the stack pushing its results. 's' is the subject
-- string, 'r' is the final position of the match, and 'ptop'
-- the index in the stack where some useful values were pushed.
-- Returns the number of results pushed. (If the list produces no
-- results, push the final position of the match.)

local function getcaptures(capture, s, stream, r, valuetable, ...)
    local n = 0;
    local cs = { cap = 0 }
    local out = { outindex = 0; out = {} }
    if capture[cs.cap].kind ~= Cclose then -- is there any capture?
        cs.ocap = capture
        cs.s = s;
        cs.stream = stream
        cs.ptopcount, cs.ptop = retcount(...)
        repeat -- collect their values
            n = n + pushcapture(cs, out, valuetable)
        until cs.ocap[cs.cap].kind == Cclose
    end
    if n == 0 then -- no capture values?
        if not r then
            return
        else
            return r
        end
    end
    return unpack(out.out, 1, out.outindex)
end

local function getcapturesruntime(capture, stream, captop, valuetable, ...)
    local n = 0;
    local cs = { cap = 0 }
    local out = { outindex = 0; out = {} }
    cs.ocap = capture
    cs.stream = stream
    cs.ptopcount, cs.ptop = retcount(...)
    repeat -- collect their values
        if not checknextcap(cs,  captop) then break end
        n = pushcapture(cs, out, valuetable)
    until cs.cap == captop
    return cs.cap, out.out, out.outindex
end

return {
    getcaptures = getcaptures,
    runtimecap = runtimecap,
    getcapturesruntime = getcapturesruntime,
}

