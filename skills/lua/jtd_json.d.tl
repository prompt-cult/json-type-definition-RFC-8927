-- Teal declaration for jtd_json.lua (vendored zero-dependency JSON decoder).
-- Copy this file next to jtd_json.lua so `tl check` types the call sites.

local record jtd_json
   -- Unique sentinel that decode() returns for JSON null. Never nil, so it
   -- survives table indexing the way a decoded null must.
   null: any

   -- Metatables used to tag decoded arrays and objects: the generated
   -- validators read __jsontype to tell `[]` from `{}`.
   array_mt: {string:any}
   object_mt: {string:any}

   -- Maximum nesting depth accepted before decode() reports an error.
   MAX_DEPTH: integer

   -- Decode JSON text: value on success, (nil, message) on failure.
   decode: function(chunk: string): any, string

   -- Encode a value as JSON text. For tests and error messages only.
   encode: function(value: any): string
end

return jtd_json
