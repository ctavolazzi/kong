-- JWT verification module
-- Adapted version of x25/luajwt for Kong. It provides various improvements and
-- an OOP architecture allowing the JWT to be parsed and verified separately,
-- avoiding multiple parsings.
--
-- @see https://github.com/x25/luajwt

local json = require "cjson"
local b64 = require "ngx.base64"
local buffer = require "string.buffer"
local openssl_digest = require "resty.openssl.digest"
local openssl_hmac = require "resty.openssl.hmac"
local openssl_pkey = require "resty.openssl.pkey"


local rep = string.rep
local sub = string.sub
local find = string.find
local type = type
local time = ngx.time
local pairs = pairs
local error = error
local pcall = pcall
local insert = table.insert
local unpack = unpack
local assert = assert
local tostring = tostring
local setmetatable = setmetatable
local getmetatable = getmetatable
local encode_base64url = b64.encode_base64url
local decode_base64url = b64.decode_base64url


--- Supported algorithms for signing tokens.
local alg_sign = {
  HS256 = function(data, key) return openssl_hmac.new(key, "sha256"):final(data) end,
  HS384 = function(data, key) return openssl_hmac.new(key, "sha384"):final(data) end,
  HS512 = function(data, key) return openssl_hmac.new(key, "sha512"):final(data) end,
  RS256 = function(data, key)
    local digest = openssl_digest.new("sha256")
    assert(digest:update(data))
    return assert(openssl_pkey.new(key):sign(digest))
  end,
  RS384 = function(data, key)
    local digest = openssl_digest.new("sha384")
    assert(digest:update(data))
    return assert(openssl_pkey.new(key):sign(digest))
  end,
  RS512 = function(data, key)
    local digest = openssl_digest.new("sha512")
    assert(digest:update(data))
    return assert(openssl_pkey.new(key):sign(digest))
  end,
  ES256 = function(data, key)
    local pkey = openssl_pkey.new(key)
    local sig = assert(pkey:sign(data, "sha256", nil, { ecdsa_use_raw = true }))
    if not sig then
      return nil
    end
    return sig
  end,
  ES384 = function(data, key)
    local pkey = openssl_pkey.new(key)
    local sig = assert(pkey:sign(data, "sha384", nil, { ecdsa_use_raw = true }))
    if not sig then
      return nil
    end
    return sig
  end
}


--- Supported algorithms for verifying tokens.
local alg_verify = {
  HS256 = function(data, signature, key) return signature == alg_sign.HS256(data, key) end,
  HS384 = function(data, signature, key) return signature == alg_sign.HS384(data, key) end,
  HS512 = function(data, signature, key) return signature == alg_sign.HS512(data, key) end,
  RS256 = function(data, signature, key)
    local pkey, _ = openssl_pkey.new(key)
    assert(pkey, "Consumer Public Key is Invalid")
    local digest = openssl_digest.new("sha256")
    assert(digest:update(data))
    return pkey:verify(signature, digest)
  end,
  RS384 = function(data, signature, key)
    local pkey, _ = openssl_pkey.new(key)
    assert(pkey, "Consumer Public Key is Invalid")
    local digest = openssl_digest.new("sha384")
    assert(digest:update(data))
    return pkey:verify(signature, digest)
  end,
  RS512 = function(data, signature, key)
    local pkey, _ = openssl_pkey.new(key)
    assert(pkey, "Consumer Public Key is Invalid")
    local digest = openssl_digest.new("sha512")
    assert(digest:update(data))
    return pkey:verify(signature, digest)
  end,
  -- https://www.rfc-editor.org/rfc/rfc7518#section-3.4
  ES256 = function(data, signature, key)
    local pkey, _ = openssl_pkey.new(key)
    assert(pkey, "Consumer Public Key is Invalid")
    --  The ECDSA P-256 SHA-256 digital signature for a JWS is validated as
    --  follows:

    --  1.  The JWS Signature value MUST be a 64-octet sequence.  If it is
    --      not a 64-octet sequence, the validation has failed.
    assert(#signature == 64, "Signature must be 64 bytes.")
    return pkey:verify(signature, data, "sha256", nil, { ecdsa_use_raw = true })
  end,
  ES384 = function(data, signature, key)
    --  Signing and validation with the ECDSA P-384 SHA-384 and ECDSA P-521
    --  SHA-512 algorithms is performed identically to the procedure for
    --  ECDSA P-256 SHA-256 -- just using the corresponding hash algorithms
    --  with correspondingly larger result values.  For ECDSA P-384 SHA-384,
    --  R and S will be 384 bits each, resulting in a 96-octet sequence.  For
    --  ECDSA P-521 SHA-512, R and S will be 521 bits each, resulting in a
    --  132-octet sequence.
    local pkey, _ = openssl_pkey.new(key)
    assert(#signature == 96, "Signature must be 96 bytes.")
    return pkey:verify(signature, data, "sha384", nil, { ecdsa_use_raw = true })
  end
}


--- base 64 encoding
-- @param input String to base64 encode
-- @return Base64 encoded string
local function base64_encode(input)
  local result = encode_base64url(input)
  return result
end


--- base 64 decode
-- @param input String to base64 decode
-- @return Base64 decoded string
local function base64_decode(input)
  local remainder = #input % 4

  if remainder > 0 then
    local padlen = 4 - remainder
    input = input .. rep("=", padlen)
  end

  return decode_base64url(input)
end


--- Tokenize a string by delimiter
-- Used to separate the header, claims and signature part of a JWT
-- @param str String to tokenize
-- @param div Delimiter
-- @param len Number of parts to retrieve
-- @return A table of strings
local function tokenize(str, div, len)
  local result, idx, pos = {}, 1, 0

  local iter = function()
    return find(str, div, pos, true)
  end

  for st, sp in iter do
    result[idx] = sub(str, pos, st - 1)
    idx = idx + 1
    pos = sp + 1
    len = len - 1
    if len <= 1 then
      break
    end
  end

  result[idx] = sub(str, pos)
  return result
end


--- Parse a JWT
-- Parse a JWT and validate header values.
-- @param token JWT to parse
-- @return A table containing base64 and decoded headers, claims and signature
local function decode_token(token)
  -- Get b64 parts
  local header_64, claims_64, signature_64 = unpack(tokenize(token, ".", 3))

  -- Decode JSON
  local ok, header, claims, signature = pcall(function()
    return json.decode(base64_decode(header_64)),
           json.decode(base64_decode(claims_64)),
           base64_decode(signature_64)
  end)
  if not ok then
    return nil, "invalid JSON"
  end

  if not header.alg or type(header.alg) ~= "string" or not alg_verify[header.alg] then
    return nil, "invalid alg"
  end

  if not claims then
    return nil, "invalid claims"
  end

  if not signature then
    return nil, "invalid signature"
  end

  return {
    token = token,
    header_64 = header_64,
    claims_64 = claims_64,
    signature_64 = signature_64,
    header = header,
    claims = claims,
    signature = signature
  }
end


-- For test purposes
local function encode_token(data, key, alg, header)
  if type(data) ~= "table" then
    error("Argument #1 must be table", 2)
  end

  if type(key) ~= "string" then
    error("Argument #2 must be string", 2)
  end

  if header and type(header) ~= "table" then
    error("Argument #4 must be a table", 2)
  end

  alg = alg or "HS256"
  if not alg_sign[alg] then
    error("Algorithm not supported", 2)
  end

  local header = header or { typ = "JWT", alg = alg }
  local buf = buffer.new()

  buf:put(base64_encode(json.encode(header))):put(".")
     :put(base64_encode(json.encode(data)))

  local signature = alg_sign[alg](buf:tostring(), key)

  buf:put(".")
     :put(base64_encode(signature))

  return buf:get()
end


local err_list_mt = {}


local function add_error(errors, k, v)
  if not errors then
    errors = {}
  end

  if errors and errors[k] then
    if getmetatable(errors[k]) ~= err_list_mt then
      errors[k] = setmetatable({errors[k]}, err_list_mt)
    end

    insert(errors[k], v)
  else
    errors[k] = v
  end

  return errors
end


--[[

  JWT public interface

]]--


local _M = {}


_M.__index = _M


--- Instantiate a JWT parser
-- Parse a JWT and instantiate a JWT parser for further operations
-- Return errors instead of an instance if any encountered
-- @param token JWT to parse
-- @return JWT parser
-- @return error if any
function _M:new(token)
  if type(token) ~= "string" then
    error("Token must be a string, got " .. tostring(token), 2)
  end

  local token, err = decode_token(token)
  if err then
    return nil, err
  end

  return setmetatable(token, _M)
end


--- Verify a JWT signature
-- Verify the current JWT signature against a given key
-- @param key Key against which to verify the signature
-- @return A boolean indicating if the signature if verified or not
function _M:verify_signature(key)
  return alg_verify[self.header.alg](self.header_64 .. "." .. self.claims_64, self.signature, key)
end


function _M:base64_decode(input)
  return base64_decode(input)
end


--- Registered claims according to RFC 7519 Section 4.1
local registered_claims = {
  nbf = {
    type = "number",
    check = function(nbf)
      if nbf > time() then
        return "token not valid yet"
      end
    end
  },
  exp = {
    type = "number",
    check = function(exp)
      if exp <= time() then
        return "token expired"
      end
    end
  }
}


--- Verify registered claims (according to RFC 7519 Section 4.1)
-- Claims are verified by type and a check.
-- @param claims_to_verify A list of claims to verify.
-- @return A boolean indicating true if no errors zere found
-- @return A list of errors
function _M:verify_registered_claims(claims_to_verify)
  if not claims_to_verify then
    claims_to_verify = {}
  end

  local errors
  local claim
  local claim_rules

  for _, claim_name in pairs(claims_to_verify) do
    claim = self.claims[claim_name]
    claim_rules = registered_claims[claim_name]

    if type(claim) ~= claim_rules.type then
      errors = add_error(errors, claim_name, "must be a " .. claim_rules.type)

    else
      local check_err = claim_rules.check(claim)
      if check_err then
        errors = add_error(errors, claim_name, check_err)
      end
    end
  end

  return errors == nil, errors
end


--- Check that the maximum allowed expiration is not reached
-- @param maximum_expiration of the claim
-- @return A Boolean indicating true if the claim has reached the maximum
-- allowed expiration time
-- @return error if any
function _M:check_maximum_expiration(maximum_expiration)
  if maximum_expiration <= 0 then
    return true
  end

  local exp = self.claims.exp
  if exp == nil or exp - time() > maximum_expiration then
    return false, { exp = "exceeds maximum allowed expiration" }
  end

  return true
end


_M.encode = encode_token


return _M
