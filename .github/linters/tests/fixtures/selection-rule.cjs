// Test-only CLI oracle: record every linted lexical path, even clean files.
const fs = require("node:fs");
module.exports = {
  names: ["TESTSELECT"],
  tags: ["test"],
  description: "Record the complete selected file list",
  parser: "none",
  function(params) {
    fs.appendFileSync(process.env.MARKDOWN_SELECTION_LOG, JSON.stringify(params.name) + "\n");
  },
};
