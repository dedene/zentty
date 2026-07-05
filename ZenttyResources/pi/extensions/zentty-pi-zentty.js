import register from "../../shared/pi-family/zentty-pi-family-zentty.js"

if (!process.env.ZENTTY_AGENT_CANONICAL_NAME) {
  // The shared module reads this lazily because ESM imports run before this body.
  process.env.ZENTTY_AGENT_CANONICAL_NAME = "Pi"
}

export default register
