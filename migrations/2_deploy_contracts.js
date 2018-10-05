const Multiownable = artifacts.require('Multiownable');

module.exports = async function (deployer) {
    deployer.deploy(Multiownable);
};
