const EVMRevert = require('./helpers/EVMRevert');

require('chai')
    .use(require('chai-as-promised'))
    .use(require('chai-bignumber')(web3.BigNumber))
    .should();

const MultiAttackable = artifacts.require('./impl/MultiAttackable.sol');
const MultiAttacker = artifacts.require('./impl/MultiAttacker.sol');

contract('MultiAttack', function ([_, wallet1, wallet2, wallet3, wallet4, wallet5]) {
    it('should handle reentracy attack', async function () {
        const victim = await MultiAttackable.new();
        const hacker = await MultiAttacker.new();

        // Prepare victim wallet
        await victim.addOwners([wallet1, wallet2]);
        await victim.resignOwnership({ from: _ });
        await web3.eth.sendTransaction({ from: _, to: victim.address, value: web3.toWei(3, 'ether') });

        // Try reentrace attack
        await victim.transferTo(hacker.address, web3.toWei(1, 'ether'), { from: wallet1 });
        await victim.transferTo(hacker.address, web3.toWei(1, 'ether'), { from: wallet2 }).should.be.rejectedWith(EVMRevert);

        (await web3.eth.getBalance(victim.address)).should.be.bignumber.equal(web3.toWei(3, 'ether'));
    });
});
