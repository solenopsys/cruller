const util = require('node:util');
const text = 'Hello, TypeScript!';
console.log(util.styleText(['bold', 'red'], text));
module.exports = {
    text
};
export {};
