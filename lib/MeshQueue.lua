-- FIFO mesh-build scheduling and completion state.
--
-- A queue entry is deliberately just the existing job record. The service
-- owns ordering, de-duplication, cancellation, and status; ChunkMesher
-- remains responsible for running the job coroutine and deciding its work.
local MeshQueue = {}

function MeshQueue.new()
  local queue = {}
  local pending, index, completion = {}, {}, {}

  function queue.key(id, slot)
    return id .. ":" .. slot
  end

  function queue.find(id, slot)
    return index[queue.key(id, slot)]
  end

  function queue.enqueue(job, force)
    local key = queue.key(job.id, job.slot)
    if force then completion[key] = nil end
    if index[key] then return index[key] end
    index[key] = job
    pending[#pending + 1] = job
    return job
  end

  function queue.finish(job, ok)
    local key = queue.key(job.id, job.slot)
    index[key] = nil
    completion[key] = ok and "complete" or "failed"
    for i, queued in ipairs(pending) do
      if queued == job then
        table.remove(pending, i)
        break
      end
    end
  end

  function queue.remove(job, status)
    local key = queue.key(job.id, job.slot)
    index[key] = nil
    if status then completion[key] = status end
    for i, queued in ipairs(pending) do
      if queued == job then
        table.remove(pending, i)
        break
      end
    end
  end

  function queue.removeIf(predicate, status)
    for i = #pending, 1, -1 do
      local job = pending[i]
      if predicate(job) then
        queue.remove(job, status)
      end
    end
  end

  function queue.pending()
    return #pending
  end

  function queue.jobPending(id, slot)
    return index[queue.key(id, slot)] ~= nil
  end

  function queue.status(id, slot)
    local key = queue.key(id, slot)
    if index[key] then return "pending" end
    return completion[key]
  end

  function queue.pick(urgent)
    local pick = pending[1]
    if urgent then
      for _, job in ipairs(pending) do
        if job.urgent then
          pick = job
          break
        end
      end
    end
    return pick
  end

  function queue.list()
    return pending
  end

  function queue.index()
    return index
  end

  function queue.completion()
    return completion
  end

  return queue
end

return MeshQueue
