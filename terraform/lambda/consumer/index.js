exports.handler = async (event) => {
  for (const record of event.Records || []) {
    console.log('msg', record.body);
  }
};
