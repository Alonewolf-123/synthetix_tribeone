const ethers = require('ethers');
const { assert } = require('../../contracts/common');
const { bootstrapDual } = require('../utils/bootstrap');
const { appendEscrows, retrieveEscrowParameters } = require('../utils/escrow');
const { finalizationOnL2 } = require('../utils/optimism');
const { ensureBalance } = require('../utils/balances');
const { approveIfNeeded } = require('../utils/approve');

describe('migrateDebt() integration tests (L1, L2)', () => {
	const ctx = this;
	bootstrapDual({ ctx });

	let user;
	let DebtMigratorOnEthereum, RewardEscrowV2, Synthetix, SynthetixDebtShare;

	let initialParametersL1,
		initialParametersL2,
		initialCollateralBalanceL1,
		initialLiquidBalanceL1,
		initialDebtShareBalanceL1;

	let postParametersL1 = {};
	let escrowEntriesData = {};
	const escrowNum = 26;
	const escrowBatches = 2;
	const numExtraEntries = 0;
	const totalEntriesCreated = escrowNum * escrowBatches + numExtraEntries;
	const SNXAmount = ethers.utils.parseEther('1000');
	const amountToIssue = ethers.utils.parseEther('100');

	before('ensure the user has enough SNX', async () => {
		user = ctx.l1.users.owner;
		await ensureBalance({ ctx: ctx.l1, symbol: 'SNX', user, balance: SNXAmount });
	});

	before('approve reward escrow if needed', async () => {
		({ Synthetix, RewardEscrowV2 } = ctx.l1.contracts);
		user = ctx.l1.users.owner;

		await approveIfNeeded({
			token: Synthetix,
			owner: user,
			beneficiary: RewardEscrowV2,
			amount: SNXAmount,
		});
	});

	before('create and append escrow entries', async () => {
		escrowEntriesData = await appendEscrows({
			ctx: ctx.l1,
			user,
			escrowBatches,
			numExtraEntries,
			escrowNum,
			escrowEntryAmount: ethers.constants.One,
		});
	});

	before('stake some SNX', async () => {
		Synthetix = Synthetix.connect(user);

		const tx = await Synthetix.issueSynths(amountToIssue);
		const { gasUsed } = await tx.wait();
		console.log(`issueSynths() gas used: ${Math.round(gasUsed / 1000).toString()}k`);
	});

	before('record initial state', async () => {
		initialParametersL1 = await retrieveEscrowParameters({ ctx: ctx.l1 });
		initialParametersL2 = await retrieveEscrowParameters({ ctx: ctx.l2 });

		({ Synthetix, SynthetixDebtShare } = ctx.l1.contracts);
		user = ctx.l1.users.owner;
		initialCollateralBalanceL1 = await Synthetix.collateral(user.address);
		initialLiquidBalanceL1 = await Synthetix.balanceOf(user.address);
		initialDebtShareBalanceL1 = await SynthetixDebtShare.balanceOf(user.address);
	});

	describe('when the user migrates their debt', () => {
		let migrateDebtReceipt;
		let userLiquidBalanceL2;
		let userCollateralBalanceL2;
		let userDebtShareBalanceL2;
		let rewardEscrowBalanceL2;

		before('target contracts and users', () => {
			({ Synthetix, RewardEscrowV2 } = ctx.l2.contracts);

			user = ctx.l2.users.owner;
		});

		before('record current values', async () => {
			userLiquidBalanceL2 = await Synthetix.balanceOf(user.address);
			userCollateralBalanceL2 = await Synthetix.collateral(user.address);
			userDebtShareBalanceL2 = await SynthetixDebtShare.balanceOf(user.address);
			rewardEscrowBalanceL2 = await Synthetix.balanceOf(RewardEscrowV2.address);
		});

		before('migrateDebt()', async () => {
			({ DebtMigratorOnEthereum } = ctx.l1.contracts);

			DebtMigratorOnEthereum = DebtMigratorOnEthereum.connect(ctx.l1.users.owner);
			const tx = await DebtMigratorOnEthereum.migrateDebt(user.address);
			migrateDebtReceipt = await tx.wait();
			console.log(
				`migrateDebt() gas used: ${Math.round(migrateDebtReceipt.gasUsed / 1000).toString()}k`
			);
		});

		it('should update the L1 escrow state', async () => {
			postParametersL1 = await retrieveEscrowParameters({ ctx: ctx.l1 });

			assert.bnEqual(
				postParametersL1.escrowedBalance,
				postParametersL1.escrowedBalance.sub(initialParametersL1.escrowedBalance)
			);
			assert.bnEqual(postParametersL1.userNumVestingEntries, 0);
			assert.bnEqual(postParametersL1.userEscrowedBalance, 0);
			assert.bnEqual(postParametersL1.userVestedAccountBalance, 0);
		});

		it('should update the L1 Synthetix state', async () => {
			({ Synthetix } = ctx.l1.contracts);
			user = ctx.l1.users.owner;

			assert.bnEqual(await Synthetix.collateral(user.address), 0);
			assert.bnEqual(await Synthetix.balanceOf(user.address), 0);
			assert.bnEqual(await SynthetixDebtShare.balanceOf(user.address), 0);
		});

		// --------------------------
		// Wait...
		// --------------------------

		describe('when the escrow gets picked up in L2', () => {
			before('listen for completion', async () => {
				await finalizationOnL2({
					ctx,
					transactionHash: migrateDebtReceipt.transactionHash,
				});
			});

			it('should update the L2 escrow state', async () => {
				const postParametersL2 = await retrieveEscrowParameters({ ctx: ctx.l2 });
				assert.bnEqual(
					postParametersL2.escrowedBalance,
					initialParametersL2.escrowedBalance.add(escrowEntriesData.totalEscrowed)
				);
				assert.bnEqual(
					postParametersL2.userNumVestingEntries,
					initialParametersL2.userNumVestingEntries.add(totalEntriesCreated)
				);
				assert.bnEqual(
					postParametersL2.userEscrowedBalance,
					initialParametersL2.userEscrowedBalance.add(escrowEntriesData.totalEscrowed)
				);
				assert.bnEqual(
					postParametersL2.userVestedAccountBalance,
					initialParametersL2.userVestedAccountBalance
				);
			});

			it('should update the L2 Synthetix state', async () => {
				({ Synthetix, RewardEscrowV2, SynthetixDebtShare } = ctx.l2.contracts);

				user = ctx.l2.users.owner;

				assert.bnEqual(
					await Synthetix.balanceOf(user.address),
					userLiquidBalanceL2.add(initialLiquidBalanceL1)
				);
				assert.bnEqual(
					await Synthetix.balanceOf(RewardEscrowV2.address),
					rewardEscrowBalanceL2.add(escrowEntriesData.totalEscrowed)
				);
				assert.bnEqual(
					await Synthetix.collateral(user.address),
					userCollateralBalanceL2.add(initialCollateralBalanceL1)
				);
				assert.bnEqual(
					await SynthetixDebtShare.balanceOf(user.address),
					userDebtShareBalanceL2.add(initialDebtShareBalanceL1)
				);
			});
		});
	});
});
