local bump = require "lib.bump"
local class = require "lib.middleclass"
local vector = require "lib.vector"
if arg[#arg] == "-debug" then require("mobdebug").start() end

-- game variables
local is_paused = false
local speed = 256
local pc
local blocks = {}
local enemies = {}

-- generic drawable sprite (for prototyping, just a filled rect)
local Sprite = class('Sprite')

function Sprite:draw()
  love.graphics.setColor(self.color)
  love.graphics.rectangle("fill", self.x, self.y, self.width, self.height)
end

function Sprite:push(other, x, y)
  local actualX, actualY, cols, len = world:move(self, x, y, function(item, other)
    return "cross"
  end)

  self.x = x
  self.y = y
  
  for i=1, len do
    local col = cols[i]
    if col.other ~= other then
      local other_x = col.other.x
      local other_y = col.other.y
      
      if col.normal.x == -1 then
        other_x = other_x + 32 -- self.x + self.width
      elseif col.normal.x == 1 then
        other_x = other_x - 32 -- self.x - col.other.width
      end
      
      if col.normal.y == -1 then
        other_y = other_y + 32 -- self.y + self.height
      elseif col.normal.y == 1 then
        other_y = other_y - 32 -- self.y - col.other.height
      end
      
      col.other:push(self, other_x, other_y)
    end
  end
end

-- Playable Character
local Character = class('Character', Sprite)
function Character:initialize()
  self.color = {255, 0, 0}
  self.width = 32
  self.height = 50
  self.x = 0
  self.y = 0
  Sprite.initialize(self)
end

function Character:update(dt)
  local x = self.x
  local y = self.y
  if love.keyboard.isDown("right") then
    x = x + (speed * dt)
  elseif love.keyboard.isDown("left") then
    x = x - (speed * dt)
  end

  if love.keyboard.isDown("down") then
    y = y + (speed * dt)
  elseif love.keyboard.isDown("up") then
    y = y - (speed * dt)
  end
  
  self:push(nil, x, y)
end

-- enemy
local Enemy = class('Enemy', Sprite)
function Enemy:initialize(x, y)
  self.color = {0, 0, 255}
  self.width = 32
  self.height = 32
  self.x = x
  self.y = y
  Sprite.initialize(self)
end

function Enemy:update(dt)
  local dir = vector(pc.x - self.x, pc.y - self.y)
  dir:normalizeInplace()
  dir = dir * speed * dt
  local x = self.x + dir.x
  local y = self.y + dir.y

  local actualX, actualY, cols, len = world:move(self, x, y)
  self.x = actualX
  self.y = actualY
end

-- movable block
local Block = class('Block', Sprite)
function Block:initialize(x, y)
  self.color = {40, 40, 40}
  self.width = 32
  self.height = 32
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
  local num_blocks_x = win_width / 32
  local num_blocks_y = win_height / 32
  
  local block
  local block_ix = 1
  for y = 1, num_blocks_y do
    for x = 1, num_blocks_x do
      -- avoid creating blocks at 1,1 or 1,2, so they don't overlap w/ the pc
      if x > 1 or y > 2 then
        if math.random(6) == 1 then
          if math.random(20) == 1 then
            enemy = Enemy:new((x - 1) * 32, (y - 1) * 32)
            table.insert(enemies, enemy)
            addSprite(enemy)
          else
            block = Block:new((x - 1) * 32, (y - 1) * 32)
            table.insert(blocks, block)
            addSprite(block)
          end
        end
      end
    end
  end
end

-- game callbacks
function love.load(arg)
  -- nearest neightbor & full-screen
  love.graphics.setDefaultFilter( 'nearest', 'nearest' )
  --love.window.setFullscreen(true)
  
  -- prepare simple AABB collision world w/ cell size
  world = bump.newWorld(64)
  pc = Character:new()
  addSprite(pc)
  
  generateBlocks()
end

function love.update(dt)
  if is_paused then return end
  pc:update(dt)
  for i = 1, #enemies do
    enemies[i]:update(dt)
  end
end

function love.draw()
  pc:draw()
  
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

