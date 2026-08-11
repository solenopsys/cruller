"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const { UserAccount, UserType } = require('./user.ts');
const account = new UserAccount('john', 100, UserType.Admin);
console.log(account);
