exports.handler = async (event) => {
  return { ok: true, table: process.env.TABLE_NAME };
};
