local bump = require "lib/bump"
local class = require "lib/middleclass"
local vector = require "lib/vector"
local baton = require "lib/baton"

if os.getenv("LOCAL_LUA_DEBUGGER_VSCODE") == "1" then
  require("lldebugger").start()
end

-- game variables
local player_speed = 400
local beast_speed = 150
local grid_size = 32
local players = {}
local blocks = {}
local enemies = {}

-- generic drawable sprite (for prototyping, just a filled rect)
local Sprite = class('Sprite')

function Sprite:draw()
  love.graphics.setColor(self.color)
  love.graphics.rectangle("fill", self.x, self.y, self.width, self.height)
end

function Sprite:push(other, x, y)
  local actualX, actualY, cols, len = world:check(self, x, y, function(item, other)
    return "cross"
  end)
  
  local success = true
  for i=1, len do
    local col = cols[i]
    if col.other ~= other then
      local other_x = col.other.x
      local other_y = col.other.y
      
      if col.normal.x == -1 then
        other_x = other_x + grid_size -- self.x + self.width
      elseif col.normal.x == 1 then
        other_x = other_x - grid_size -- self.x - col.other.width
      end
      
      if col.normal.y == -1 then
        other_y = other_y + grid_size -- self.y + self.height
      elseif col.normal.y == 1 then
        other_y = other_y - grid_size -- self.y - col.other.height
      end
      
      if not col.other:push(self, other_x, other_y) then
        success = false
      end
    end
  end

  if success then
    actualX, actualY = world:move(self, x, y, function(item, other)
      return "cross"
    end) 
    self.x = actualX
    self.y = actualY 
  end
  return success
end

-- Playable Character
local Character = class('Character', Sprite)
function Character:initialize(x, y, input)
  self.input = input
  self.color = {140/255, 60/255, 140/255}
  self.width = grid_size
  self.height = grid_size
  self.x = x
  self.y = y
  self.dx = 0
  self.dy = 0
  Sprite.initialize(self)
end

function Character:update(dt)
  self.input:update(dt)
  local x = self.x
  local y = self.y
  local dx, dy = self.input:get('move')
  
  -- user is moving
  if dx ~= 0 or dy ~= 0 then
    x = x + (dx * player_speed * dt)
    y = y + (dy * player_speed * dt)
  end

  -- user just stopped moving in this dimension
  -- snap to the grid
  if dx == 0 and self.dx ~= 0 then
    local dx = x % grid_size
    if dx < (grid_size/2) then
      x = x - dx
    else
      x = x + (grid_size - dx)
    end
  end
  if dy == 0 and self.dy ~= 0 then
    local dy = y % grid_size
    if dy < (grid_size/2) then
      y = y - dy
    else
      y = y + (grid_size - dy)
    end
  end

  self.dx = dx
  self.dy = dy
  
  self:push(nil, x, y)
end

-- enemy
local Enemy = class('Enemy', Sprite)
function Enemy:initialize(x, y)
  self.color = {140/255, 60/255, 60/255}
  self.width = grid_size
  self.height = grid_size
  self.x = x
  self.y = y
  Sprite.initialize(self)
end

function Enemy:update(dt)
  -- TODO: make enemies move towards *closest* player, not *first* player
  local dir = vector(players[1].x - self.x, players[1].y - self.y)
  dir:normalizeInplace()
  dir = dir * beast_speed * dt
  local x = self.x + dir.x
  local y = self.y + dir.y

  -- often the beasts get *super* close to going through a hole, but not quite
  -- we can fix this by a slight adjustment: if either dimension is super-close
  -- to being on a grid line, adjust it so it is on the grid line
  local x_offset = x % grid_size
  if math.abs(x_offset) < 2 then
    if x_offset > 0 and dir.x < 0 then
      x = x - x_offset
    else
      x = x + x_offset
    end
  end

  local y_offset = y % grid_size
  if math.abs(y_offset) < 2 then
    if y_offset > 0 and dir.y < 0 then
      y = y - y_offset
    else
      y = y + y_offset
    end
  end

  local actualX, actualY, cols, len = world:move(self, x, y, function(item, other)
    return "slide"
  end)
  self.x = actualX
  self.y = actualY
end

function Enemy:push(other, x, y)
  -- *check* if there would be a collision
  local actualX, actualY, cols, len = world:check(self, x, y, function(item, other)
    return "cross"
  end)
  
  -- we get squished if there would've been a collision
  -- TODO: we should probably check that it's not a player on the other side...
  if #cols ~= 0 then
    local ix
    for i=1, #enemies do
      if enemies[i] == self then
        ix = i
      end
    end
    table.remove(enemies, ix)
    world:remove(self)
  end
  return false
end

-- movable block
local Block = class('Block', Sprite)
function Block:initialize(x, y)
  self.color = {200/255, 200/255, 200/255}
  self.width = grid_size
  self.height = grid_size
  self.x = x
  self.y = y
  Sprite.initialize(self)
end

-- helper functions
function addSprite(spr)
  world:add(spr, spr.x, spr.y, spr.width, spr.height)
end

function generateBlocks()
  local win_width = love.graphics.getWidth()
  local win_height = love.graphics.getHeight()
  local num_blocks_x = win_width / grid_size
  local num_blocks_y = win_height / grid_size
  
  local block
  local block_ix = 1
  for y = 1, num_blocks_y do
    for x = 1, num_blocks_x do
      -- avoid creating blocks at 1,1 or 1,2, so they don't overlap w/ the players
      if x > 1 or y > 2 then
        if math.random(6) == 1 then
          if math.random(20) == 1 then
            enemy = Enemy:new((x - 1) * grid_size, (y - 1) * grid_size)
            table.insert(enemies, enemy)
            addSprite(enemy)
          else
            block = Block:new((x - 1) * grid_size, (y - 1) * grid_size)
            table.insert(blocks, block)
            addSprite(block)
          end
        end
      end
    end
  end
end

-- game callbacks
function love.load()
  local joysticks = love.joystick.getJoysticks()
  local num_players = #joysticks
  if num_players == 0 then
    num_players = 1 -- if there are no joysticks, fallback to one keyboard/mouse player
  end

  for i=1, num_players do
    table.insert(players, Character:new(0, (i-1) * grid_size, baton.new({
      controls = {
        move_left = {'key:a', 'axis:leftx-', 'button:dpleft'},
        move_right = {'key:d', 'axis:leftx+', 'button:dpright'},
        move_up = {'key:w', 'axis:lefty-', 'button:dpup'},
        move_down = {'key:s', 'axis:lefty+', 'button:dpdown'},
        pull = {'key:space', 'button:a'},
      },
      pairs = {
        move = {'move_left', 'move_right', 'move_up', 'move_down'},
      },
      deadzone = 0.2,
      squareDeadzone = true, -- helps w/ player grid snapping when transitioning from diagonal to vert/horiz movement
      joystick = joysticks[i]
    })))
  end

  -- nearest neightbor & full-screen
  love.graphics.setDefaultFilter( 'nearest', 'nearest' )
  love.window.setFullscreen(true)
  love.mouse.setVisible(false)
  love.graphics.setBackgroundColor({150/255, 150/255, 150/255})
  
  -- prepare simple AABB collision world w/ cell size
  world = bump.newWorld(64)
  for i = 1, #players do
    addSprite(players[i])
  end
  
  generateBlocks()
end

function love.update(dt)
  for i = 1, #players do
    players[i]:update(dt)
  end
  for i = 1, #enemies do
    enemies[i]:update(dt)
  end
end

function love.draw()
  for i = 1, #players do
    players[i]:draw()
  end
  
  for i = 1, #blocks do
    blocks[i]:draw()
  end
  
  for i = 1, #enemies do
    local enemy = enemies[i]
    enemy:draw()
  end
end

function love.keypressed(k)
   if k == 'escape' then
      love.event.quit()
   end
end

