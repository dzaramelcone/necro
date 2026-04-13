-- wrk script: pipeline N requests per send
-- Usage: wrk -s pipeline.lua -- N
init = function(args)
   local depth = tonumber(args[1]) or 16
   local r = {}
   for i = 1, depth do
      r[i] = wrk.format("GET", "/", nil, nil)
   end
   req = table.concat(r)
end

request = function()
   return req
end
