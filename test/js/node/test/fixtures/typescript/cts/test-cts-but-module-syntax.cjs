"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.text = void 0;
const node_util_1 = __importDefault(require("node:util"));
exports.text = 'Hello, TypeScript!';
console.log(node_util_1.default.styleText(['bold', 'red'], exports.text));
