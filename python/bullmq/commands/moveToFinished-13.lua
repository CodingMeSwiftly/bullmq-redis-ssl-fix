--[[
  Move job from active to a finished status (completed o failed)
  A job can only be moved to completed if it was active.
  The job must be locked before it can be moved to a finished status,
  and the lock must be released in this script.
    Input:
      KEYS[1] wait key
      KEYS[2] active key
      KEYS[3] prioritized key
      KEYS[4] event stream key
      KEYS[5] stalled key
      -- Rate limiting
      KEYS[6] rate limiter key
      KEYS[7] delayed key
      KEYS[8] paused key
      KEYS[9] meta key
      KEYS[10] pc priority counter
      KEYS[11] completed/failed key
      KEYS[12] jobId key
      KEYS[13] metrics key
      ARGV[1]  jobId
      ARGV[2]  timestamp
      ARGV[3]  msg property returnvalue / failedReason
      ARGV[4]  return value / failed reason
      ARGV[5]  target (completed/failed)
      ARGV[6]  event data (? maybe just send jobid).
      ARGV[7]  fetch next?
      ARGV[8]  keys prefix
      ARGV[9]  opts
      opts - token - lock token
      opts - keepJobs
      opts - lockDuration - lock duration in milliseconds
      opts - attempts max attempts
      opts - attemptsMade
      opts - maxMetricsSize
      opts - fpof - fail parent on fail
      opts - rdof - remove dependency on fail
    Output:
      0 OK
      -1 Missing key.
      -2 Missing lock.
      -3 Job not in active set
      -4 Job has pending dependencies
      -6 Lock is not owned by this client
    Events:
      'completed/failed'
]]
local rcall = redis.call
--- Includes
--[[
  Functions to collect metrics based on a current and previous count of jobs.
  Granualarity is fixed at 1 minute.
]] 
--[[
  Function to loop in batches.
  Just a bit of warning, some commands as ZREM
  could receive a maximum of 7000 parameters per call.
]]
local function batches(n, batchSize)
  local i = 0
  return function()
    local from = i * batchSize + 1
    i = i + 1
    if (from <= n) then
      local to = math.min(from + batchSize - 1, n)
      return from, to
    end
  end
end
local function collectMetrics(metaKey, dataPointsList, maxDataPoints,
                                 timestamp)
    -- Increment current count
    local count = rcall("HINCRBY", metaKey, "count", 1) - 1
    -- Compute how many data points we need to add to the list, N.
    local prevTS = rcall("HGET", metaKey, "prevTS")
    if not prevTS then
        -- If prevTS is nil, set it to the current timestamp
        rcall("HSET", metaKey, "prevTS", timestamp, "prevCount", 0)
        return
    end
    local N = math.floor((timestamp - prevTS) / 60000)
    if N > 0 then
        local delta = count - rcall("HGET", metaKey, "prevCount")
        -- If N > 1, add N-1 zeros to the list
        if N > 1 then
            local points = {}
            points[1] = delta
            for i = 2, N do
                points[i] = 0
            end
            for from, to in batches(#points, 7000) do
                rcall("LPUSH", dataPointsList, unpack(points, from, to))
            end
        else
            -- LPUSH delta to the list
            rcall("LPUSH", dataPointsList, delta)
        end
        -- LTRIM to keep list to its max size
        rcall("LTRIM", dataPointsList, 0, maxDataPoints - 1)
        -- update prev count with current count
        rcall("HSET", metaKey, "prevCount", count, "prevTS", timestamp)
    end
end
--[[
  Function to return the next delayed job timestamp.
]] 
local function getNextDelayedTimestamp(delayedKey)
  local result = rcall("ZRANGE", delayedKey, 0, 0, "WITHSCORES")
  if #result then
    local nextTimestamp = tonumber(result[2])
    if (nextTimestamp ~= nil) then 
      nextTimestamp = nextTimestamp / 0x1000
    end
    return nextTimestamp
  end
end
--[[
  Function to move job from prioritized state to active.
]]
local function moveJobFromPriorityToActive(priorityKey, activeKey, priorityCounterKey)
  local prioritizedJob = rcall("ZPOPMIN", priorityKey)
  if #prioritizedJob > 0 then
    rcall("LPUSH", activeKey, prioritizedJob[1])
    return prioritizedJob[1]
  else
    rcall("DEL", priorityCounterKey)
  end
end
--[[
  Function to move job from wait state to active.
  Input:
    keys[1] wait key
    keys[2] active key
    keys[3] prioritized key
    keys[4] stream events key
    keys[5] stalled key
    -- Rate limiting
    keys[6] rate limiter key
    keys[7] delayed key
    keys[8] paused key
    keys[9] meta key
    keys[10] pc priority counter
    opts - token - lock token
    opts - lockDuration
    opts - limiter
]]
-- Includes
--[[
  Function to push back job considering priority in front of same prioritized jobs.
]]
local function pushBackJobWithPriority(prioritizedKey, priority, jobId)
  -- in order to put it at front of same prioritized jobs
  -- we consider prioritized counter as 0
  local score = priority * 0x100000000
  rcall("ZADD", prioritizedKey, score, jobId)
end
local function prepareJobForProcessing(keys, keyPrefix, targetKey, jobId, processedOn,
    maxJobs, expireTime, opts)
  local jobKey = keyPrefix .. jobId
  -- Check if we need to perform rate limiting.
  if maxJobs then
    local rateLimiterKey = keys[6];
    -- check if we exceeded rate limit, we need to remove the job and return expireTime
    if expireTime > 0 then
      -- remove from active queue and add back to the wait list
      rcall("LREM", keys[2], 1, jobId)
      local priority = tonumber(rcall("HGET", jobKey, "priority")) or 0
      if priority == 0 then
        rcall("RPUSH", targetKey, jobId)
      else
        pushBackJobWithPriority(keys[3], priority, jobId)
      end
      -- Return when we can process more jobs
      return {0, 0, expireTime, 0}
    end
    local jobCounter = tonumber(rcall("INCR", rateLimiterKey))
    if jobCounter == 1 then
      local limiterDuration = opts['limiter'] and opts['limiter']['duration']
      local integerDuration = math.floor(math.abs(limiterDuration))
      rcall("PEXPIRE", rateLimiterKey, integerDuration)
    end
  end
  local lockKey = jobKey .. ':lock'
  -- get a lock
  if opts['token'] ~= "0" then
    rcall("SET", lockKey, opts['token'], "PX", opts['lockDuration'])
  end
  rcall("XADD", keys[4], "*", "event", "active", "jobId", jobId, "prev", "waiting")
  rcall("HSET", jobKey, "processedOn", processedOn)
  rcall("HINCRBY", jobKey, "attemptsMade", 1)
  return {rcall("HGETALL", jobKey), jobId, 0, 0} -- get job data
end
--[[
  Function to recursively move from waitingChildren to failed.
]]
-- Includes
--[[
  Validate and move parent to active if needed.
]]
-- Includes
--[[
  Add delay marker if needed.
]]
-- Includes
local function addDelayMarkerIfNeeded(targetKey, delayedKey)
  if rcall("LLEN", targetKey) == 0 then
    local nextTimestamp = getNextDelayedTimestamp(delayedKey)
    if nextTimestamp ~= nil then
      rcall("LPUSH", targetKey, "0:" .. nextTimestamp)
    end
  end
end
--[[
  Function to add job considering priority.
]]
-- Includes
--[[
  Function priority marker to wait if needed
  in order to wake up our workers and to respect priority
  order as much as possible
]]
local function addPriorityMarkerIfNeeded(waitKey)
  local waitLen = rcall("LLEN", waitKey)
  if waitLen == 0 then
    rcall("LPUSH", waitKey, "0:0")
  end
end
local function addJobWithPriority(waitKey, prioritizedKey, priority, paused, jobId, priorityCounterKey)
  local prioCounter = rcall("INCR", priorityCounterKey)
  local score = priority * 0x100000000 + bit.band(prioCounter, 0xffffffffffff)
  rcall("ZADD", prioritizedKey, score, jobId)
  if not paused then
    addPriorityMarkerIfNeeded(waitKey)
  end
end
--[[
  Function to check for the meta.paused key to decide if we are paused or not
  (since an empty list and !EXISTS are not really the same).
]]
local function getTargetQueueList(queueMetaKey, waitKey, pausedKey)
  if rcall("HEXISTS", queueMetaKey, "paused") ~= 1 then
    return waitKey, false
  else
    return pausedKey, true
  end
end
local function moveParentToWaitIfNeeded(parentQueueKey, parentDependenciesKey, parentKey, parentId, timestamp)
  local isParentActive = rcall("ZSCORE", parentQueueKey .. ":waiting-children", parentId)
  if rcall("SCARD", parentDependenciesKey) == 0 and isParentActive then 
    rcall("ZREM", parentQueueKey .. ":waiting-children", parentId)
    local parentWaitKey = parentQueueKey .. ":wait"
    local parentTarget, paused = getTargetQueueList(parentQueueKey .. ":meta", parentWaitKey,
      parentQueueKey .. ":paused")
    local jobAttributes = rcall("HMGET", parentKey, "priority", "delay")
    local priority = tonumber(jobAttributes[1]) or 0
    local delay = tonumber(jobAttributes[2]) or 0
    if delay > 0 then
      local delayedTimestamp = tonumber(timestamp) + delay 
      local score = delayedTimestamp * 0x1000
      local parentDelayedKey = parentQueueKey .. ":delayed" 
      rcall("ZADD", parentDelayedKey, score, parentId)
      rcall("XADD", parentQueueKey .. ":events", "*", "event", "delayed", "jobId", parentId,
        "delay", delayedTimestamp)
      addDelayMarkerIfNeeded(parentTarget, parentDelayedKey)
    else
      if priority == 0 then
        rcall("RPUSH", parentTarget, parentId)
      else
        addJobWithPriority(parentWaitKey, parentQueueKey .. ":prioritized", priority, paused,
          parentId, parentQueueKey .. ":pc")
      end
      rcall("XADD", parentQueueKey .. ":events", "*", "event", "waiting", "jobId", parentId,
        "prev", "waiting-children")
    end
  end
end
local function moveParentFromWaitingChildrenToFailed( parentQueueKey, parentKey, parentId, jobIdKey, timestamp)
  if rcall("ZREM", parentQueueKey .. ":waiting-children", parentId) == 1 then
    rcall("ZADD", parentQueueKey .. ":failed", timestamp, parentId)
    local failedReason = "child " .. jobIdKey .. " failed"
    rcall("HMSET", parentKey, "failedReason", failedReason, "finishedOn", timestamp)
    rcall("XADD", parentQueueKey .. ":events", "*", "event", "failed", "jobId", parentId, "failedReason",
      failedReason, "prev", "waiting-children")
    local rawParentData = rcall("HGET", parentKey, "parent")
    if rawParentData ~= false then
      local parentData = cjson.decode(rawParentData)
      if parentData['fpof'] then
        moveParentFromWaitingChildrenToFailed(
          parentData['queueKey'],
          parentData['queueKey'] .. ':' .. parentData['id'],
          parentData['id'],
          parentKey,
          timestamp
        )
      elseif parentData['rdof'] then
        local grandParentKey = parentData['queueKey'] .. ':' .. parentData['id']
        local grandParentDependenciesSet = grandParentKey .. ":dependencies"
        if rcall("SREM", grandParentDependenciesSet, parentKey) == 1 then
          moveParentToWaitIfNeeded(parentData['queueKey'], grandParentDependenciesSet,
            grandParentKey, parentData['id'], timestamp)
        end
      end
    end
  end
end
--[[
  Updates the delay set, by moving delayed jobs that should
  be processed now to "wait".
     Events:
      'waiting'
]]
-- Includes
-- Try to get as much as 1000 jobs at once
local function promoteDelayedJobs(delayedKey, waitKey, targetKey, prioritizedKey,
                                  eventStreamKey, prefix, timestamp, paused, priorityCounterKey)
    local jobs = rcall("ZRANGEBYSCORE", delayedKey, 0, (timestamp + 1) * 0x1000, "LIMIT", 0, 1000)
    if (#jobs > 0) then
        rcall("ZREM", delayedKey, unpack(jobs))
        for _, jobId in ipairs(jobs) do
            local jobKey = prefix .. jobId
            local priority =
                tonumber(rcall("HGET", jobKey, "priority")) or 0
            if priority == 0 then
                -- LIFO or FIFO
                rcall("LPUSH", targetKey, jobId)
            else
                addJobWithPriority(waitKey, prioritizedKey, priority, paused,
                  jobId, priorityCounterKey)
            end
            -- Emit waiting event
            rcall("XADD", eventStreamKey, "*", "event", "waiting", "jobId",
                  jobId, "prev", "delayed")
            rcall("HSET", jobKey, "delay", 0)
        end
    end
end
--[[
  Functions to remove jobs by max age.
]]
-- Includes
--[[
  Function to remove job.
]]
-- Includes
--[[
  Check if this job has a parent. If so we will just remove it from
  the parent child list, but if it is the last child we should move the parent to "wait/paused"
  which requires code from "moveToFinished"
]]
--[[
  Functions to destructure job key.
  Just a bit of warning, these functions may be a bit slow and affect performance significantly.
]]
local getJobIdFromKey = function (jobKey)
  return string.match(jobKey, ".*:(.*)")
end
local getJobKeyPrefix = function (jobKey, jobId)
  return string.sub(jobKey, 0, #jobKey - #jobId)
end
local function moveParentToWait(parentPrefix, parentId, emitEvent)
  local parentTarget = getTargetQueueList(parentPrefix .. "meta", parentPrefix .. "wait", parentPrefix .. "paused")
  rcall("RPUSH", parentTarget, parentId)
  if emitEvent then
    local parentEventStream = parentPrefix .. "events"
    rcall("XADD", parentEventStream, "*", "event", "waiting", "jobId", parentId, "prev", "waiting-children")
  end
end
local function removeParentDependencyKey(jobKey, hard, parentKey, baseKey)
  if parentKey then
    local parentDependenciesKey = parentKey .. ":dependencies"
    local result = rcall("SREM", parentDependenciesKey, jobKey)
    if result > 0 then
      local pendingDependencies = rcall("SCARD", parentDependenciesKey)
      if pendingDependencies == 0 then
        local parentId = getJobIdFromKey(parentKey)
        local parentPrefix = getJobKeyPrefix(parentKey, parentId)
        local numRemovedElements = rcall("ZREM", parentPrefix .. "waiting-children", parentId)
        if numRemovedElements == 1 then
          if hard then
            if parentPrefix == baseKey then
              removeParentDependencyKey(parentKey, hard, nil, baseKey)
              rcall("DEL", parentKey, parentKey .. ':logs',
                parentKey .. ':dependencies', parentKey .. ':processed')
            else
              moveParentToWait(parentPrefix, parentId)
            end
          else
            moveParentToWait(parentPrefix, parentId, true)
          end
        end
      end
    end
  else
    local missedParentKey = rcall("HGET", jobKey, "parentKey")
    if( (type(missedParentKey) == "string") and missedParentKey ~= "" and (rcall("EXISTS", missedParentKey) == 1)) then
      local parentDependenciesKey = missedParentKey .. ":dependencies"
      local result = rcall("SREM", parentDependenciesKey, jobKey)
      if result > 0 then
        local pendingDependencies = rcall("SCARD", parentDependenciesKey)
        if pendingDependencies == 0 then
          local parentId = getJobIdFromKey(missedParentKey)
          local parentPrefix = getJobKeyPrefix(missedParentKey, parentId)
          local numRemovedElements = rcall("ZREM", parentPrefix .. "waiting-children", parentId)
          if numRemovedElements == 1 then
            if hard then
              if parentPrefix == baseKey then
                removeParentDependencyKey(missedParentKey, hard, nil, baseKey)
                rcall("DEL", missedParentKey, missedParentKey .. ':logs',
                  missedParentKey .. ':dependencies', missedParentKey .. ':processed')
              else
                moveParentToWait(parentPrefix, parentId)
              end
            else
              moveParentToWait(parentPrefix, parentId, true)
            end
          end
        end
      end
    end
  end
end
local function removeJob(jobId, hard, baseKey)
  local jobKey = baseKey .. jobId
  removeParentDependencyKey(jobKey, hard, nil, baseKey)
  rcall("DEL", jobKey, jobKey .. ':logs',
    jobKey .. ':dependencies', jobKey .. ':processed')
end
local function removeJobsByMaxAge(timestamp, maxAge, targetSet, prefix)
  local start = timestamp - maxAge * 1000
  local jobIds = rcall("ZREVRANGEBYSCORE", targetSet, start, "-inf")
  for i, jobId in ipairs(jobIds) do
    removeJob(jobId, false, prefix)
  end
  rcall("ZREMRANGEBYSCORE", targetSet, "-inf", start)
end
--[[
  Functions to remove jobs by max count.
]]
-- Includes
local function removeJobsByMaxCount(maxCount, targetSet, prefix)
  local start = maxCount
  local jobIds = rcall("ZREVRANGE", targetSet, start, -1)
  for i, jobId in ipairs(jobIds) do
    removeJob(jobId, false, prefix)
  end
  rcall("ZREMRANGEBYRANK", targetSet, 0, -(maxCount + 1))
end
--[[
  Function to trim events, default 10000.
]]
local function trimEvents(metaKey, eventStreamKey)
  local maxEvents = rcall("HGET", metaKey, "opts.maxLenEvents")
  if maxEvents ~= false then
    rcall("XTRIM", eventStreamKey, "MAXLEN", "~", maxEvents)
  else
    rcall("XTRIM", eventStreamKey, "MAXLEN", "~", 10000)
  end
end
--[[
  Validate and move or add dependencies to parent.
]]
-- Includes
local function updateParentDepsIfNeeded(parentKey, parentQueueKey, parentDependenciesKey,
  parentId, jobIdKey, returnvalue, timestamp )
  local processedSet = parentKey .. ":processed"
  rcall("HSET", processedSet, jobIdKey, returnvalue)
  moveParentToWaitIfNeeded(parentQueueKey, parentDependenciesKey, parentKey, parentId, timestamp)
end
local function getRateLimitTTL(maxJobs, rateLimiterKey)
  if maxJobs and maxJobs <= tonumber(rcall("GET", rateLimiterKey) or 0) then
    local pttl = rcall("PTTL", rateLimiterKey)
    if pttl == 0 then
      rcall("DEL", rateLimiterKey)
    end
    if pttl > 0 then
      return pttl
    end
  end
  return 0
end
local jobIdKey = KEYS[12]
if rcall("EXISTS", jobIdKey) == 1 then -- // Make sure job exists
    local opts = cmsgpack.unpack(ARGV[9])
    local token = opts['token']
    local attempts = opts['attempts']
    local attemptsMade = opts['attemptsMade']
    local maxMetricsSize = opts['maxMetricsSize']
    local maxCount = opts['keepJobs']['count']
    local maxAge = opts['keepJobs']['age']
    if token ~= "0" then
        local lockKey = jobIdKey .. ':lock'
        local lockToken = rcall("GET", lockKey)
        if lockToken == token then
            rcall("DEL", lockKey)
            rcall("SREM", KEYS[5], ARGV[1])
        else
            if lockToken then
                -- Lock exists but token does not match
                return -6
            else
                -- Lock is missing completely
                return -2
            end
        end
    end
    if rcall("SCARD", jobIdKey .. ":dependencies") ~= 0 then -- // Make sure it does not have pending dependencies
        return -4
    end
    local parentReferences = rcall("HMGET", jobIdKey, "parentKey", "parent")
    local parentKey = parentReferences[1] or ""
    local parentId = ""
    local parentQueueKey = ""
    if parentReferences[2] ~= false then
        local jsonDecodedParent = cjson.decode(parentReferences[2])
        parentId = jsonDecodedParent['id']
        parentQueueKey = jsonDecodedParent['queueKey']
    end
    local jobId = ARGV[1]
    local timestamp = ARGV[2]
    -- Remove from active list (if not active we shall return error)
    local numRemovedElements = rcall("LREM", KEYS[2], -1, jobId)
    if (numRemovedElements < 1) then return -3 end
    -- Trim events before emiting them to avoid trimming events emitted in this script
    trimEvents(KEYS[9], KEYS[4])
    -- If job has a parent we need to
    -- 1) remove this job id from parents dependencies
    -- 2) move the job Id to parent "processed" set
    -- 3) push the results into parent "results" list
    -- 4) if parent's dependencies is empty, then move parent to "wait/paused". Note it may be a different queue!.
    if parentId == "" and parentKey ~= "" then
        parentId = getJobIdFromKey(parentKey)
        parentQueueKey = getJobKeyPrefix(parentKey, ":" .. parentId)
    end
    if parentId ~= "" then
        if ARGV[5] == "completed" then
            local dependenciesSet = parentKey .. ":dependencies"
            if rcall("SREM", dependenciesSet, jobIdKey) == 1 then
                updateParentDepsIfNeeded(parentKey, parentQueueKey,
                                         dependenciesSet, parentId, jobIdKey,
                                         ARGV[4], timestamp)
            end
        else
            if opts['fpof'] then
                moveParentFromWaitingChildrenToFailed(parentQueueKey, parentKey,
                                            parentId, jobIdKey, timestamp)
            elseif opts['rdof'] then
                local dependenciesSet = parentKey .. ":dependencies"
                if rcall("SREM", dependenciesSet, jobIdKey) == 1 then
                    moveParentToWaitIfNeeded(parentQueueKey, dependenciesSet,
                        parentKey, parentId, timestamp)
                end
            end
        end
    end
    -- Remove job?
    if maxCount ~= 0 then
        local targetSet = KEYS[11]
        -- Add to complete/failed set
        rcall("ZADD", targetSet, timestamp, jobId)
        rcall("HMSET", jobIdKey, ARGV[3], ARGV[4], "finishedOn", timestamp)
        -- "returnvalue" / "failedReason" and "finishedOn"
        -- Remove old jobs?
        local prefix = ARGV[8]
        if maxAge ~= nil then
            removeJobsByMaxAge(timestamp, maxAge, targetSet, prefix)
        end
        if maxCount ~= nil and maxCount > 0 then
            removeJobsByMaxCount(maxCount, targetSet, prefix)
        end
    else
        rcall("DEL", jobIdKey, jobIdKey .. ':logs', jobIdKey .. ':processed')
        if parentKey ~= "" then
            removeParentDependencyKey(jobIdKey, false, parentKey)
        end
    end
    rcall("XADD", KEYS[4], "*", "event", ARGV[5], "jobId", jobId, ARGV[3],
          ARGV[4])
    if ARGV[5] == "failed" then
        if tonumber(attemptsMade) >= tonumber(attempts) then
            rcall("XADD", KEYS[4], "*", "event", "retries-exhausted", "jobId",
                  jobId, "attemptsMade", attemptsMade)
        end
    end
    -- Collect metrics
    if maxMetricsSize ~= "" then
        collectMetrics(KEYS[13], KEYS[13] .. ':data', maxMetricsSize, timestamp)
    end
    -- Try to get next job to avoid an extra roundtrip if the queue is not closing,
    -- and not rate limited.
    if (ARGV[7] == "1") then
        local target, paused = getTargetQueueList(KEYS[9], KEYS[1], KEYS[8])
        -- Check if there are delayed jobs that can be promoted
        promoteDelayedJobs(KEYS[7], KEYS[1], target, KEYS[3],
                           KEYS[4], ARGV[8], timestamp, paused, KEYS[10])
        local maxJobs = tonumber(opts['limiter'] and opts['limiter']['max'])
        -- Check if we are rate limited first.
        local expireTime = getRateLimitTTL(maxJobs, KEYS[6])
        if expireTime > 0 then return {0, 0, expireTime, 0} end
        -- paused queue
        if paused then return {0, 0, 0, 0} end
        jobId = rcall("RPOPLPUSH", KEYS[1], KEYS[2])
        if jobId then
            if string.sub(jobId, 1, 2) == "0:" then
                rcall("LREM", KEYS[2], 1, jobId)
                -- If jobId is special ID 0:delay (delay greater than 0), then there is no job to process
                -- but if ID is 0:0, then there is at least 1 prioritized job to process
                if jobId == "0:0" then
                    jobId = moveJobFromPriorityToActive(KEYS[3], KEYS[2], KEYS[10])
                    return prepareJobForProcessing(KEYS, ARGV[8], target, jobId, timestamp,
                        maxJobs, expireTime, opts)
                end
            else
                return prepareJobForProcessing(KEYS, ARGV[8], target, jobId, timestamp, maxJobs,
                    expireTime, opts)
            end
        else
            jobId = moveJobFromPriorityToActive(KEYS[3], KEYS[2], KEYS[10])
            if jobId then
                return prepareJobForProcessing(KEYS, ARGV[8], target, jobId, timestamp, maxJobs,
                    expireTime, opts)
            end
        end
        -- Return the timestamp for the next delayed job if any.
        local nextTimestamp = getNextDelayedTimestamp(KEYS[7])
        if nextTimestamp ~= nil then
            -- The result is guaranteed to be positive, since the
            -- ZRANGEBYSCORE command would have return a job otherwise.
            return {0, 0, 0, nextTimestamp}
        end
    end
    local waitLen = rcall("LLEN", KEYS[1])
    if waitLen == 0 then
        local activeLen = rcall("LLEN", KEYS[2])
        if activeLen == 0 then
            local prioritizedLen = rcall("ZCARD", KEYS[3])
            if prioritizedLen == 0 then
                rcall("XADD", KEYS[4], "*", "event", "drained")
            end
        end
    end
    return 0
else
    return -1
end
